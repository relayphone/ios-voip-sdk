// Builds the standalone runtime package: the runtime and its loader for the simulator, `cksim`
// for the Mac, the behaviour profile, the documentation and `build-info.json`.
//
// Usage: node tools/build-runtime.ts <new output directory> [--archs arm64,x86_64]
import {
  copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { isMain, main, option, repository, run } from './command.ts';
import { type BuildInfo, isVersion, manifest, sourceDigest } from './runtime-package.ts';

const objectiveC = ['CKInterposition', 'CKPushDelivery', 'CKPushLaunch'];

function swiftFiles(folder: string): string[] {
  return readdirSync(join(repository, folder))
    .filter(name => name.endsWith('.swift'))
    .sort()
    .map(name => join(repository, folder, name));
}

/** Builds the package in a new directory and returns its manifest. */
export function buildRuntime(output: string, architectures: readonly string[]): BuildInfo {
  if (existsSync(output)) throw new Error(`Output already exists: ${output}`);
  if (architectures.length === 0 || architectures.some(name => !['arm64', 'x86_64'].includes(name))) {
    throw new Error('Architectures must be arm64, x86_64 or both.');
  }
  const version = readFileSync(join(repository, 'VERSION'), 'utf8').trim();
  if (!isVersion(version)) throw new Error('Invalid runtime VERSION');
  const sdk = run('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-path']);
  const metadata = existsSync(
    join(sdk, 'System/Library/Frameworks/PushKit.framework/Headers/PKVoIPPushMetadata.h'),
  ) ? 1 : 0;
  mkdirSync(dirname(output), { recursive: true });
  const work = mkdtempSync(join(dirname(output), '.cksim-runtime-build-'));
  try {
    const packageDirectory = join(work, 'package');
    mkdirSync(join(packageDirectory, 'profiles'), { recursive: true });
    const runtimes: string[] = [];
    const loaders: string[] = [];
    for (const architecture of architectures) {
      const target = `${architecture}-apple-ios18.0-simulator`;
      const objects = objectiveC.map(source => {
        const object = join(work, `${source}-${architecture}.o`);
        run('xcrun', [
          '--sdk', 'iphonesimulator', 'clang', '-target', target, '-isysroot', sdk, '-fobjc-arc',
          '-fmodules', `-DCKSIM_RUNTIME_VERSION="${version}"`, `-DCKSIM_HAS_VOIP_METADATA=${metadata}`,
          '-c', join(repository, 'Sources/Interposition', `${source}.m`), '-o', object,
        ]);
        return object;
      });
      const runtime = join(work, `CKSimRuntime-${architecture}.dylib`);
      run('xcrun', [
        '--sdk', 'iphonesimulator', 'swiftc', '-target', target, '-sdk', sdk, '-swift-version', '6',
        '-O', '-emit-library', '-module-name', 'CKSimRuntime',
        '-import-objc-header', join(repository, 'Sources/Interposition/CKRuntimeSeam.h'),
        ...swiftFiles('Sources/CKSimProtocol'), ...swiftFiles('Sources/Engine'), ...objects,
        '-Xlinker', '-install_name', '-Xlinker', '@rpath/CKSimRuntime.dylib', '-o', runtime,
      ]);
      const loader = join(work, `CKSimLoader-${architecture}.dylib`);
      run('xcrun', [
        '--sdk', 'iphonesimulator', 'clang', '-target', target, '-isysroot', sdk, '-fobjc-arc',
        '-dynamiclib', '-framework', 'Foundation', join(repository, 'Sources/Interposition/CKLoader.m'),
        '-o', loader,
      ]);
      runtimes.push(runtime);
      loaders.push(loader);
    }
    for (const [name, inputs] of [['CKSimRuntime.dylib', runtimes], ['CKSimLoader.dylib', loaders]] as const) {
      const library = join(packageDirectory, name);
      run('lipo', ['-create', ...inputs, '-output', library]);
      run('codesign', ['-s', '-', '--force', library]);
    }

    // cksim runs on the Mac that hosts the simulator.
    const scratch = join(work, 'swift');
    const swiftArguments = [
      'build', '-c', 'release', '--product', 'cksim', '--scratch-path', scratch,
      ...architectures.flatMap(architecture => ['--arch', architecture]),
    ];
    run('swift', swiftArguments, { inherit: true });
    const products = run('swift', [...swiftArguments, '--show-bin-path']);
    copyFileSync(join(products, 'cksim'), join(packageDirectory, 'cksim'));
    run('chmod', ['755', join(packageDirectory, 'cksim')]);

    for (const profile of readdirSync(join(repository, 'Sources/Engine/Resources'))) {
      if (profile.endsWith('.json')) {
        copyFileSync(join(repository, 'Sources/Engine/Resources', profile), join(packageDirectory, 'profiles', profile));
      }
    }
    copyFileSync(join(repository, 'VERSION'), join(packageDirectory, 'VERSION'));
    copyFileSync(join(repository, 'docs/simulator-runtime.md'), join(packageDirectory, 'README.md'));

    const git = (...args: string[]) => run('git', args);
    // The tracked sources the package is built from.
    const inputs = git(
      'ls-files', 'VERSION', 'docs/simulator-runtime.md', 'Package.swift', 'Package.resolved', 'Sources', 'tools',
    ).split('\n').filter(path => path && existsSync(join(repository, path)));
    const info: BuildInfo = {
      schemaVersion: 1,
      version,
      profile: 'ios-27.0',
      sourceCommit: git('rev-parse', 'HEAD'),
      sourceDirty: git('status', '--porcelain') !== '',
      sourceInputsSHA256: sourceDigest(repository, inputs),
      sourceDateEpoch: Number(git('show', '-s', '--format=%ct', 'HEAD')),
      toolchain: {
        xcode: run('xcodebuild', ['-version']),
        swift: run('xcrun', ['swiftc', '--version']),
        clang: run('xcrun', ['clang', '--version']),
      },
      sdk: {
        version: run('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-version']),
        build: run('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-build-version']),
      },
      sdkPath: sdk,
      architectures: [...architectures],
      files: manifest(packageDirectory),
    };
    writeFileSync(join(packageDirectory, 'build-info.json'), `${JSON.stringify(info, null, 2)}\n`);
    renameSync(packageDirectory, output);
    return info;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

if (isMain(import.meta.url)) {
  await main(() => {
    const output = process.argv[2];
    if (!output || output.startsWith('--')) {
      throw new Error('Usage: node tools/build-runtime.ts <new output directory> [--archs arm64,x86_64]');
    }
    const architectures = (option(process.argv, 'archs') ?? 'arm64,x86_64').split(',');
    const info = buildRuntime(resolve(output), architectures);
    console.log(`Built ${basename(resolve(output))} ${info.version} for ${info.architectures.join(' and ')}.`);
  });
}
