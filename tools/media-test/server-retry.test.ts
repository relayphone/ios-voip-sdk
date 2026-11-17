import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { unusedPort } from './fixture-runtime.ts';
import { ServerStartError, startServer, type ServerPorts } from './server.ts';

interface Attempt { pid: number; ports: ServerPorts; previousAlive: boolean }
function fixture(failures: number, stream: 'stdout' | 'stderr' = 'stdout', bind = true) {
  const directory = mkdtempSync(join(tmpdir(), 'server-retry-test-'));
  const binary = join(directory, 'server.ts'), history = join(directory, 'attempts.json');
  writeFileSync(binary, `#!/usr/bin/env node
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer as tcpServer } from 'node:net';
import { createServer as httpServer } from 'node:http';
import { once } from 'node:events';
const config = JSON.parse(readFileSync(process.argv.at(-1), 'utf8'));
const history = ${JSON.stringify(history)};
const rows = existsSync(history) ? JSON.parse(readFileSync(history, 'utf8')) : [];
let previousAlive = false;
if (rows.at(-1)) { try { process.kill(rows.at(-1).pid, 0); previousAlive = true; } catch {} }
rows.push({ pid: process.pid, previousAlive, ports: { signal: config.port, tcp: config.rtc.tcp_port, udp: config.rtc.udp_port } });
writeFileSync(history, JSON.stringify(rows));
if (rows.length <= ${failures}) {
  if (${bind}) {
    // A competing listener takes the port after the caller's unused-port probe closed.
    const competing = tcpServer().listen(config.rtc.tcp_port, '127.0.0.1');
    await once(competing, 'listening');
    const candidate = tcpServer();
    candidate.once('error', error => {
      if (error.code !== 'EADDRINUSE') throw error;
      process.${stream}.write('listen tcp :' + config.rtc.tcp_port + ': bind: address already in use\\n', () => process.exit(1));
    });
    candidate.listen(config.rtc.tcp_port, '127.0.0.1');
  } else process.${stream}.write('configuration rejected; previous error was address already in use\\n', () => process.exit(1));
} else httpServer((_, response) => response.setHeader('Content-Type', 'application/json').end('{"rooms":[]}')).listen(config.port, '127.0.0.1');
`);
  chmodSync(binary, 0o700);
  return { directory, binary, attempts: () => JSON.parse(readFileSync(history, 'utf8')) as Attempt[],
    remove: () => rmSync(directory, { recursive: true, force: true }) };
}

for (const stream of ['stdout', 'stderr'] as const) {
  test(`a real TCP bind collision on ${stream} starts once more with fresh ports after exit`, async () => {
    const f = fixture(1, stream);
    let server: Awaited<ReturnType<typeof startServer>> | undefined;
    try {
      server = await startServer(f.binary, f.directory);
      const attempts = f.attempts(); assert.equal(attempts.length, 2);
      const [first, second] = attempts; assert.ok(first && second);
      assert.equal(second.previousAlive, false);
      for (const port of Object.values(second.ports)) assert.ok(!Object.values(first.ports).includes(port));
      assert.equal(server.pid, second.pid);
    } finally { await server?.close(); f.remove(); }
  });
}

test('two consecutive bind failures stop after the second start', async () => {
  const f = fixture(2);
  try {
    await assert.rejects(startServer(f.binary, f.directory), ServerStartError);
    assert.equal(f.attempts().length, 2);
    assert.ok(!existsSync(join(f.directory, 'server.json')));
    assert.ok(!existsSync(join(f.directory, 'server-owner.json')));
  } finally { f.remove(); }
});

test('a non-bind startup failure never starts again even if it mentions an earlier collision', async () => {
  const f = fixture(1, 'stderr', false);
  try {
    await assert.rejects(startServer(f.binary, f.directory), ServerStartError);
    assert.equal(f.attempts().length, 1);
  } finally { f.remove(); }
});

test('an explicitly requested port is never replaced after a bind failure', async () => {
  const f = fixture(1);
  try {
    await assert.rejects(startServer(f.binary, f.directory, await unusedPort()), ServerStartError);
    assert.equal(f.attempts().length, 1);
  } finally { f.remove(); }
});
