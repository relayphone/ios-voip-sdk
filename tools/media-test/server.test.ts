import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { ServerStartError, startServer } from './server.ts';

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
    await assert.rejects(startServer(join(directory, 'missing'), directory), /Server failed:[\s\S]*ENOENT/);
    assert.ok(!existsSync(join(directory, 'server.json')));
    assert.ok(!existsSync(join(directory, 'server-owner.json')));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('stdout-only startup failure retains a redacted tail, ports and exit timing', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'server-stdout-test-'));
  const binary = join(directory, 'failure.ts'), ports = join(directory, 'ports.json');
  writeFileSync(binary, `#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
const config = JSON.parse(readFileSync(process.argv.at(-1), 'utf8'));
const [key, secret] = Object.entries(config.keys)[0];
writeFileSync(${JSON.stringify(ports)}, JSON.stringify({ signal: config.port, tcp: config.rtc.tcp_port, udp: config.rtc.udp_port }));
process.stdout.write('x'.repeat(20000) + '\\nlisten tcp 127.0.0.1:' + config.port + ': bind: address already in use ' + key + ' ' + secret + '\\n' +
  'Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl\\n', () => process.exit(1));
`);
  chmodSync(binary, 0o700);
  try {
    await assert.rejects(startServer(binary, directory), (error: unknown) => {
      assert.ok(error instanceof ServerStartError);
      assert.match(error.stdout, /address already in use <REDACTED> <REDACTED>/);
      assert.match(error.stdout, /Bearer <REDACTED>/);
      assert.match(error.stdout, /^\[truncated\]/);
      assert.equal(error.stderr, '');
      assert.ok(error.stdout.length < 8300);
      assert.deepEqual(error.ports, JSON.parse(readFileSync(ports, 'utf8')));
      assert.ok(error.exitAfterMs > 0 && error.closeAfterMs >= error.exitAfterMs);
      assert.match(error.message, /ports=\d+\/\d+\/\d+/);
      assert.match(error.message, /elapsedMs=\d+/);
      return true;
    });
    assert.ok(!existsSync(join(directory, 'server.json')));
    assert.ok(!existsSync(join(directory, 'server-owner.json')));
  } finally { rmSync(directory, {recursive:true,force:true}); }
});

test('a readiness rejection preserves the child failure received during the request', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'server-readiness-test-'));
  const binary = join(directory, 'failure.ts'), trigger = join(directory, 'exit');
  const trace = join(directory, `server-${process.pid}.jsonl`);
  const previous = process.env.MEDIA_SERVER_TRACE_DIRECTORY;
  process.env.MEDIA_SERVER_TRACE_DIRECTORY = directory;
  writeFileSync(binary, `#!/usr/bin/env node
import { existsSync } from 'node:fs';
setInterval(() => {
  if (existsSync(${JSON.stringify(trigger)})) process.stdout.write('forced bind failure\\n', () => process.exit(29));
}, 10);
`);
  chmodSync(binary, 0o700);
  const listener = createServer((_, response) => {
    writeFileSync(trigger, '');
    // Return only after the supervisor's failure reached the caller, while fetch is pending.
    void (async () => {
      const end = performance.now() + 1500;
      while (!existsSync(trace) || !readFileSync(trace, 'utf8').includes('"event":"failed"')) {
        assert.ok(performance.now() < end, 'Failure trace unavailable'); await delay(10);
      }
      response.writeHead(401).end();
    })().catch(() => response.destroy());
  });
  try {
    await new Promise<void>(resolve => listener.listen(0, '127.0.0.1', resolve));
    const address = listener.address(); assert.ok(address && typeof address !== 'string');
    await assert.rejects(startServer(binary, directory, address.port), (error: unknown) => {
      assert.ok(error instanceof ServerStartError);
      assert.equal(error.code, 29); assert.match(error.stdout, /forced bind failure/);
      return true;
    });
  } finally {
    listener.closeAllConnections(); await new Promise<void>(resolve => listener.close(() => resolve()));
    if (previous === undefined) delete process.env.MEDIA_SERVER_TRACE_DIRECTORY;
    else process.env.MEDIA_SERVER_TRACE_DIRECTORY = previous;
    rmSync(directory, { recursive: true, force: true });
  }
});
