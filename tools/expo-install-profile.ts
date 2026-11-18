import { lstatSync, readdirSync, writeFileSync } from 'node:fs';
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

function observeCommand(command: string, args: string[], seconds: number, execute: typeof run) {
  const startedAt = new Date().toISOString();
  const start = performance.now();
  try {
    const output = execute(command, args, { timeout: seconds });
    return { startedAt, elapsedMS: Math.round(performance.now() - start), outcome: 'succeeded' as const, output };
  } catch (error) {
    const diagnostic = error instanceof CommandFailure && error.stderrTail ? error.stderrTail : String(error);
    return { startedAt, elapsedMS: Math.round(performance.now() - start), outcome: 'failed' as const,
      output: diagnostic.slice(-4096) };
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

/** Runs a serial warm-simulator control after the full app's journey has completed. */
export function compareMinimalInstall(work: string, fullApp: string, simulator: string, prefix: string,
  execute: typeof run = run): void {
  try {
    const identifier = 'com.example.voip.install-probe';
    const minimalApp = join(work, 'InstallProbe.app');
    buildSimulatorApp({
      bundle: minimalApp, executable: 'InstallProbe', identifier, displayName: 'Install Probe', minimumOS: '26.0',
      sources: [join(repository, 'tools', 'SimulatorInstallProbe.swift')],
    }, (command, args, options) => execute(command, args, { timeout: 60, ...options }));
    const install = observeCommand('xcrun', ['simctl', 'install', simulator, minimalApp], 180, execute);
    const container = install.outcome === 'succeeded'
      ? observeCommand('xcrun', ['simctl', 'get_app_container', simulator, identifier, 'data'], 120, execute) : undefined;
    // Host verification can identify signed payload and work to read it. Installer logs are separate evidence.
    const verify = (app: string) =>
      observeCommand('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app], 60, execute);
    const receipt = { order: 'full-then-minimal', device: 'same-warm-simulator',
      minimal: { bundle: installBundleInventory(minimalApp), install, container, hostVerification: verify(minimalApp) },
      full: { hostVerification: verify(fullApp) } };
    writeFileSync(`${prefix}-install-comparison.json`, JSON.stringify(receipt, null, 2) + '\n');
  } catch (error) {
    console.warn(`warning: could not compare minimal simulator install: ${String(error)}`);
  }
}
