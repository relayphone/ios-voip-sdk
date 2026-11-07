// Builds the separate SwiftUI Inspector for an iOS simulator or the host Mac.
//
// Usage: node tools/build-inspector.ts <new output directory>
import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isMain, main, option, repository, run } from './command.ts';
import { buildSimulatorApp, simulatorArchitecture } from './simulator-app.ts';

/** Builds `CKSimInspector.app` in the directory and returns its path. */
export function buildInspector(output: string, platform = 'ios-simulator', execute: typeof run = run): string {
  if (platform !== 'ios-simulator' && platform !== 'macos') throw new Error(`Unsupported Inspector platform: ${platform}`);
  if (existsSync(output)) throw new Error(`Output already exists: ${output}`);
  mkdirSync(output, { recursive: true });
  const swift = (folder: string) =>
    readdirSync(join(repository, folder))
      .filter(name => name.endsWith('.swift'))
      .sort()
      .map(name => join(repository, folder, name));
  const bundle = join(output, 'CKSimInspector.app');
  const sources = [...swift('Sources/CKSimProtocol'), ...swift('Inspector')];
  if (platform === 'macos') {
    const contents = join(bundle, 'Contents');
    mkdirSync(join(contents, 'MacOS'), { recursive: true });
    const sdk = execute('xcrun', ['--sdk', 'macosx', '--show-sdk-path']);
    execute('xcrun', ['--sdk', 'macosx', 'swiftc',
      '-target', `${simulatorArchitecture()}-apple-macosx26.0`, '-sdk', sdk,
      '-swift-version', '6', '-parse-as-library', ...sources,
      '-o', join(contents, 'MacOS/CKSimInspector')]);
    writeFileSync(join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.callkitsim.inspector</string>
  <key>CFBundleExecutable</key><string>CKSimInspector</string>
  <key>CFBundleName</key><string>Call Inspector</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
`);
    execute('codesign', ['-s', '-', '--force', bundle]);
    return bundle;
  }
  buildSimulatorApp({
    bundle,
    executable: 'CKSimInspector',
    identifier: 'dev.callkitsim.inspector',
    displayName: 'Call Inspector',
    minimumOS: '17.4',
    sources,
    extraKeys:
      '  <key>NSAppTransportSecurity</key>\n  <dict>\n' +
      '    <key>NSAllowsLocalNetworking</key>\n    <true/>\n  </dict>\n',
  }, execute);
  return bundle;
}

if (isMain(import.meta.url)) {
  await main(() => {
    const output = process.argv[2];
    if (!output) throw new Error('Usage: node tools/build-inspector.ts <new output directory> [--platform macos]');
    console.log(buildInspector(resolve(output), option(process.argv, 'platform')));
  });
}
