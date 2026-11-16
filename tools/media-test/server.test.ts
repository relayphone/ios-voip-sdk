import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { startServer } from './server.ts';

test('early server exit retains bounded diagnostics and redacts local credentials', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'server-exit-test-'));
  const binary = join(directory, 'failure.ts'), credentials = join(directory, 'credentials.json');
  writeFileSync(binary, `#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
const config = JSON.parse(readFileSync(process.argv.at(-1), 'utf8'));
const [key, secret] = Object.entries(config.keys)[0];
writeFileSync(${JSON.stringify(credentials)}, JSON.stringify({ key, secret }));
process.stderr.write('x'.repeat(20000) + '\\nforced bind failure ' + key + ' ' + secret + '\\n', () => process.exit(23));
`);
  chmodSync(binary, 0o700);
  try {
    await assert.rejects(startServer(binary, directory), (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.match(error.message, /code=23/);
      assert.match(error.message, /\[truncated\]/);
      assert.match(error.message, /forced bind failure <REDACTED> <REDACTED>/);
      const { key, secret } = JSON.parse(readFileSync(credentials, 'utf8')) as { key: string; secret: string };
      assert.ok(!error.message.includes(key)); assert.ok(!error.message.includes(secret));
      assert.ok(error.message.length < 9000);
      return true;
    });
    assert.ok(!existsSync(join(directory, 'server.json')));
    assert.ok(!existsSync(join(directory, 'server-owner.json')));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('a server executable that cannot spawn reports its cause and removes credentials', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'server-spawn-test-'));
  try {
    await assert.rejects(startServer(join(directory, 'missing'), directory), /Server failed:.*\n.*ENOENT/);
    assert.ok(!existsSync(join(directory, 'server.json')));
    assert.ok(!existsSync(join(directory, 'server-owner.json')));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
