// Builds the Inspector, a separate simulator-only SwiftUI app with no SDK or device target.
//
// Usage: node tools/build-inspector.ts <new output directory>
import { existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isMain, main, repository } from './command.ts';
import { buildSimulatorApp } from './simulator-app.ts';

/** Builds `CKSimInspector.app` in the directory and returns its path. */
export function buildInspector(output: string): string {
  if (existsSync(output)) throw new Error(`Output already exists: ${output}`);
  mkdirSync(output, { recursive: true });
  const swift = (folder: string) =>
    readdirSync(join(repository, folder))
      .filter(name => name.endsWith('.swift'))
      .sort()
      .map(name => join(repository, folder, name));
  const bundle = join(output, 'CKSimInspector.app');
  buildSimulatorApp({
    bundle,
    executable: 'CKSimInspector',
    identifier: 'dev.callkitsim.inspector',
    displayName: 'Call Inspector',
    minimumOS: '17.4',
    sources: [...swift('Sources/CKSimProtocol'), ...swift('Inspector')],
    extraKeys:
      '  <key>NSAppTransportSecurity</key>\n  <dict>\n' +
      '    <key>NSAllowsLocalNetworking</key>\n    <true/>\n  </dict>\n',
  });
  return bundle;
}

if (isMain(import.meta.url)) {
  await main(() => {
    const output = process.argv[2];
    if (!output) throw new Error('Usage: node tools/build-inspector.ts <new output directory>');
    console.log(buildInspector(resolve(output)));
  });
}
