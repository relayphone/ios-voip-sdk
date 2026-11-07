import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { buildInspector } from './build-inspector.ts';
import type { run } from './command.ts';

for (const platform of [undefined, 'macos']) {
  test(`builds a signed Inspector bundle for ${platform ?? 'the default simulator'}`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'inspector-build-test-'));
    try {
      const calls: { command: string; args: readonly string[] }[] = [];
      const execute: typeof run = (command, args) => {
        calls.push({ command, args });
        return '/fixture/sdk';
      };
      const bundle = buildInspector(join(directory, 'output'), platform, execute);
      const mac = platform === 'macos';
      const plist = readFileSync(join(bundle, mac ? 'Contents/Info.plist' : 'Info.plist'), 'utf8');
      assert.match(plist, /dev.callkitsim.inspector/);
      assert.equal(plist.includes('<string>MacOSX</string>'), mac);
      assert.equal(plist.includes('LSMinimumSystemVersion'), mac);
      assert.equal(plist.includes('UIApplicationSceneManifest'), !mac);
      const compile = calls.find(call => call.args.includes('swiftc'))!;
      const target = compile.args[compile.args.indexOf('-target') + 1]!;
      assert.match(target, mac ? /-apple-macosx26.0$/ : /-apple-ios17.4-simulator$/);
      assert.equal(compile.args.at(-1), join(bundle, mac ? 'Contents/MacOS/CKSimInspector' : 'CKSimInspector'));
      assert.deepEqual(calls.at(-1), { command: 'codesign', args: ['-s', '-', '--force', bundle] });
      assert.throws(() => buildInspector(join(directory, 'output'), platform, execute), /already exists/);
      assert.throws(() => buildInspector(join(directory, 'invalid'), 'android', execute), /Unsupported/);
    } finally { rmSync(directory, { recursive: true, force: true }); }
  });
}
