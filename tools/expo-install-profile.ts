import { existsSync, globSync, lstatSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { CommandFailure, repository, run } from './command.ts';
import { buildSimulatorApp } from './simulator-app.ts';
import type { JourneySetupTrace } from './expo-journey-setup.ts';

/** Counts logical file bytes without following links out of the installed bundle. */
export function installBundleInventory(app: string) {
  const inventory = { files: 0, bytes: 0, frameworkFiles: 0, frameworkBytes: 0, dSYMFiles: 0, dSYMBytes: 0 };
  const directories = [{ directory: app, framework: false, dSYM: false }];
  for (const { directory, framework, dSYM } of directories) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const item = join(directory, entry.name);
      if (entry.isDirectory()) {
        directories.push({ directory: item, framework: framework || entry.name.endsWith('.framework'),
          dSYM: dSYM || entry.name.endsWith('.dSYM') });
      } else if (entry.isFile()) {
        const bytes = lstatSync(item).size;
        inventory.files++;
        inventory.bytes += bytes;
        if (framework) {
          inventory.frameworkFiles++;
          inventory.frameworkBytes += bytes;
        }
        if (dSYM) {
          inventory.dSYMFiles++;
          inventory.dSYMBytes += bytes;
        }
      }
    }
  }
  return inventory;
}

export function saveInstallBundleInventory(app: string, work: string): void {
  try {
    const inventory = installBundleInventory(app);
    const image = process.env.ImageVersion ?? process.env.IMAGE_VERSION;
    writeFileSync(join(work, 'results', 'install-bundle.json'), JSON.stringify({ ...inventory, image }, null, 2) + '\n');
    console.log(`Simulator install bundle ${JSON.stringify(inventory)}`);
  } catch (error) {
    console.warn(`warning: could not measure simulator install bundle: ${String(error)}`);
  }
}

function observeOperation(operation: () => string) {
  const startedAt = new Date().toISOString();
  const start = performance.now();
  try {
    const output = operation();
    return { startedAt, elapsedMS: Math.round(performance.now() - start), outcome: 'succeeded' as const, output };
  } catch (error) {
    const diagnostic = error instanceof CommandFailure && error.stderrTail ? error.stderrTail : String(error);
    return { startedAt, elapsedMS: Math.round(performance.now() - start), outcome: 'failed' as const,
      output: diagnostic.slice(-4096) };
  }
}

function observeCommand(command: string, args: string[], seconds: number, execute: typeof run) {
  return observeOperation(() => execute(command, args, { timeout: seconds }));
}

function verifyInstallBundle(app: string, execute: typeof run) {
  return observeCommand('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app], 60, execute);
}

function allocatedContents(app: string, execute: typeof run) {
  const paths = readdirSync(app).filter(name => name !== 'Frameworks');
  const frameworks = join(app, 'Frameworks');
  if (existsSync(frameworks)) paths.push(...readdirSync(frameworks).map(name => join('Frameworks', name)));
  if (!paths.length) return [];
  const output = execute('/usr/bin/du', ['-sk', ...paths.map(path => `./${path}`)], { directory: app, timeout: 30 });
  return output.split('\n').map(line => {
    const tab = line.indexOf('\t');
    const kibibytes = Number(line.slice(0, tab));
    if (tab < 1 || !Number.isSafeInteger(kibibytes)) throw new Error(`Unexpected du output: ${line}`);
    return { path: line.slice(tab + 1).replace(/^\.\//, ''), kibibytes };
  }).sort((a, b) => b.kibibytes - a.kibibytes);
}

/** Measures the original build after its journey and installs a smaller copy when debug stripping saves bytes. */
export function compareWarmInstalls(app: string, simulator: string, bundle: string, work: string, prefix: string,
  execute: typeof run = run): void {
  const receipt = `${prefix}-warm-installs.json`;
  const uninstall = () => observeCommand('xcrun', ['simctl', 'uninstall', simulator, bundle], 120, execute);
  const install = (path: string) => observeCommand('xcrun', ['simctl', 'install', simulator, path], 180, execute);
  const diskUsage = (path: string) => observeCommand('/usr/bin/du', ['-sh', path], 30, execute);
  try {
    const inventory = installBundleInventory(app);
    const allocated = diskUsage(app);
    const contents = allocatedContents(app, execute);
    const hostVerification = verifyInstallBundle(app, execute);
    const removal = uninstall();
    const first = removal.outcome === 'succeeded' ? install(app) : undefined;
    const repeat = first?.outcome === 'succeeded' ? install(app) : undefined;
    const original = { ...inventory, allocated, largest: contents.slice(0, 10), hostVerification, removal, first, repeat };
    const save = (stripped?: object) => writeFileSync(receipt, JSON.stringify({ original, stripped }, null, 2) + '\n');
    save();
    if (repeat?.outcome !== 'succeeded') return;

    const framework = contents.find(item => item.path.startsWith('Frameworks/') && item.path.endsWith('.framework'));
    const dSYMs = globSync('**/*.dSYM', { cwd: app });
    if (inventory.frameworkBytes + inventory.dSYMBytes <= inventory.bytes / 2 || (!framework && !dSYMs.length)) {
      save({ outcome: 'skipped', reason: 'Frameworks and debug symbol bundles do not dominate the app size' });
      return;
    }

    const copy = join(work, 'build', 'StrippedExample.app');
    const candidate = { framework: framework?.path, dSYMs };
    const preparation = observeOperation(() => {
      execute('/usr/bin/ditto', [app, copy], { timeout: 120 });
      let signing = '';
      if (framework) {
        const directory = join(copy, framework.path);
        const executable = execute('/usr/bin/plutil', ['-extract', 'CFBundleExecutable', 'raw', '-o', '-',
          join(directory, 'Info.plist')], { timeout: 15 });
        const originalSignature = verifyInstallBundle(join(app, framework.path), execute);
        execute('xcrun', ['strip', '-S', join(directory, executable)], { timeout: 60 });
        if (originalSignature.outcome === 'succeeded' && verifyInstallBundle(directory, execute).outcome !== 'succeeded') {
          execute('/usr/bin/codesign', ['--force', '--sign', '-', '--preserve-metadata=identifier,entitlements,flags,runtime',
            directory], { timeout: 60 });
          execute('/usr/bin/codesign', ['--verify', '--strict', directory], { timeout: 60 });
          signing = 'Re-signed the stripped framework ad hoc';
        }
      }
      for (const path of dSYMs) rmSync(join(copy, path), { recursive: true, force: true });
      return signing;
    });
    if (preparation.outcome !== 'succeeded') {
      save({ candidate, preparation });
      return;
    }
    const smaller = installBundleInventory(copy);
    const measured = { ...smaller, candidate, preparation, allocated: diskUsage(copy),
      hostVerification: verifyInstallBundle(copy, execute) };
    if (smaller.bytes >= inventory.bytes) {
      save({ ...measured, outcome: 'skipped', reason: 'Debug stripping did not reduce bundle bytes' });
      return;
    }
    if (hostVerification.outcome === 'succeeded' && measured.hostVerification.outcome !== 'succeeded') {
      save({ ...measured, outcome: 'skipped', reason: 'The stripped copy failed signature verification' });
      return;
    }
    const strippedRemoval = uninstall();
    const strippedInstall = strippedRemoval.outcome === 'succeeded' ? install(copy) : undefined;
    save({ ...measured, removal: strippedRemoval, first: strippedInstall });
  } catch (error) {
    console.warn(`warning: could not complete warm simulator install comparison: ${String(error)}`);
  }
}

/** Collects installer evidence after the measured commands and before simulator cleanup. */
export function collectInstallLog(setup: JourneySetupTrace, prefix: string, execute: typeof run = run): void {
  const window = setup.installWindow();
  if (!window) return;
  try {
    const log = observeCommand('/usr/bin/log', ['show', '--style', 'compact', '--info',
      '--start', `@${Math.floor(window.startMS / 1000)}`, '--end', `@${Math.ceil(window.endMS / 1000)}`,
      '--predicate', 'process IN {"installd", "containermanagerd", "amfid", "CoreSimulatorService", "com.apple.CoreSimulator.CoreSimulatorService"} OR subsystem BEGINSWITH "com.apple.MobileInstallation"'],
    20, execute);
    writeFileSync(`${prefix}-install-log.json`, JSON.stringify({ ...log, output: log.output.slice(-32_768) }, null, 2) + '\n');
  } catch (error) {
    console.warn(`warning: could not save installer log: ${String(error)}`);
  }
}

const probeIdentifier = 'com.example.voip.install-probe';

/** Builds the diagnostic app before simulator boot so compilation cannot compete with the device. */
export function prepareMinimalInstall(work: string, execute: typeof run = run): string | undefined {
  const minimalApp = join(work, 'build', 'InstallProbe.app');
  const build = observeOperation(() => {
    buildSimulatorApp({
      bundle: minimalApp, executable: 'InstallProbe', identifier: probeIdentifier, displayName: 'Install Probe', minimumOS: '26.0',
      sources: [join(repository, 'tools', 'SimulatorInstallProbe.swift')],
    }, (command, args, options) => execute(command, args, { ...options, timeout: 120 }));
    return '';
  });
  try {
    writeFileSync(join(work, 'results', 'install-probe-build.json'), JSON.stringify(build, null, 2) + '\n');
  } catch (error) {
    console.warn(`warning: could not save minimal simulator app build: ${String(error)}`);
  }
  if (build.outcome === 'succeeded') return minimalApp;
  console.warn(`warning: could not prepare minimal simulator app: ${build.output}`);
}

/** Runs a serial warm-simulator control after the full app's journey has completed. */
export function compareMinimalInstall(minimalApp: string, fullApp: string, simulator: string, prefix: string,
  execute: typeof run = run): void {
  try {
    const install = observeCommand('xcrun', ['simctl', 'install', simulator, minimalApp], 180, execute);
    const container = install.outcome === 'succeeded'
      ? observeCommand('xcrun', ['simctl', 'get_app_container', simulator, probeIdentifier, 'data'], 120, execute) : undefined;
    // Host verification can identify signed payload and work to read it. Installer logs are separate evidence.
    const receipt = { order: 'full-then-minimal', device: 'same-warm-simulator',
      minimal: { bundle: installBundleInventory(minimalApp), install, container, hostVerification: verifyInstallBundle(minimalApp, execute) },
      full: { hostVerification: verifyInstallBundle(fullApp, execute) } };
    writeFileSync(`${prefix}-install-comparison.json`, JSON.stringify(receipt, null, 2) + '\n');
  } catch (error) {
    console.warn(`warning: could not compare minimal simulator install: ${String(error)}`);
  }
}
