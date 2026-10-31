// Building small simulator-only apps with swiftc: the Inspector and the runtime smoke test's app.
import { mkdirSync, writeFileSync } from 'node:fs';
import { arch } from 'node:os';
import { join } from 'node:path';
import { run } from './command.ts';

export interface SimulatorApp {
  /** The `.app` bundle to create. */
  bundle: string;
  executable: string;
  identifier: string;
  displayName: string;
  minimumOS: string;
  sources: readonly string[];
  /** Extra Info.plist keys, as plist XML. */
  extraKeys?: string;
}

/** The simulator architecture of this Mac. */
export function simulatorArchitecture(): string {
  return arch() === 'x64' ? 'x86_64' : 'arm64';
}

function escape(text: string): string {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

/** The Info.plist of a simulator app with one scene. */
export function infoPlist(app: SimulatorApp): string {
  const string = (key: string, value: string) =>
    `  <key>${key}</key>\n  <string>${escape(value)}</string>\n`;
  return (
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    '<plist version="1.0">\n<dict>\n' +
    string('CFBundleIdentifier', app.identifier) +
    string('CFBundleExecutable', app.executable) +
    string('CFBundleName', app.displayName) +
    string('CFBundleDisplayName', app.displayName) +
    string('CFBundlePackageType', 'APPL') +
    string('CFBundleShortVersionString', '1.0') +
    string('CFBundleVersion', '1') +
    string('MinimumOSVersion', app.minimumOS) +
    '  <key>UIDeviceFamily</key>\n  <array>\n    <integer>1</integer>\n  </array>\n' +
    '  <key>UILaunchScreen</key>\n  <dict/>\n' +
    '  <key>UIApplicationSceneManifest</key>\n  <dict>\n' +
    '    <key>UIApplicationSupportsMultipleScenes</key>\n    <false/>\n  </dict>\n' +
    (app.extraKeys ?? '') +
    '</dict>\n</plist>\n'
  );
}

/** Compiles the sources into a signed simulator app. */
export function buildSimulatorApp(app: SimulatorApp): void {
  mkdirSync(app.bundle, { recursive: false });
  const sdk = run('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-path']);
  run('xcrun', [
    '--sdk', 'iphonesimulator', 'swiftc',
    '-target', `${simulatorArchitecture()}-apple-ios${app.minimumOS}-simulator`,
    '-sdk', sdk, '-swift-version', '6', '-parse-as-library',
    ...app.sources, '-o', join(app.bundle, app.executable),
  ]);
  writeFileSync(join(app.bundle, 'Info.plist'), infoPlist(app));
  run('codesign', ['-s', '-', '--force', app.bundle]);
}
