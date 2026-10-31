import assert from 'node:assert/strict';
import { test } from 'node:test';
import { infoPlist } from './simulator-app.ts';

test('the Info.plist names the app and escapes its strings', () => {
  const plist = infoPlist({
    bundle: 'Example.app', executable: 'Example', identifier: 'dev.example', displayName: 'A & B',
    minimumOS: '18.0', sources: [],
    extraKeys: '  <key>NSAppTransportSecurity</key>\n  <dict/>\n',
  });
  assert.match(plist, /<key>CFBundleIdentifier<\/key>\n {2}<string>dev\.example<\/string>/);
  assert.match(plist, /<key>CFBundleExecutable<\/key>\n {2}<string>Example<\/string>/);
  assert.match(plist, /<string>A &amp; B<\/string>/);
  assert.match(plist, /<key>MinimumOSVersion<\/key>\n {2}<string>18\.0<\/string>/);
  assert.match(plist, /<key>NSAppTransportSecurity<\/key>/);
  assert.ok(plist.trimEnd().endsWith('</dict>\n</plist>'));
});
