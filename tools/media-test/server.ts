import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { chmodSync, rmSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { command, deadline, unusedPort } from './fixture-runtime.ts';

// Homebrew/core@4583624f89284747817e229845754c7aee8227db (arm64_sequoia).
const macDigest = '1268330c7264fcc1626f673f5abb8cb1a1691344ac171f1941014c45fe4da214';
const linuxDigests = { x64: '1e9ee90ca301e1842b2887fc77cb122759756a9c8aeb4334ee91de3325ec43fb',
  arm64: '2af6ce091d6b3c79d1677f8ff1bbb91a8007f40b2325c059b52d38383c0830b6' } as const;
/** Verify the archive on every use, then extract a fresh executable. No unverified binary cache. */
export async function serverBinary(directory: string): Promise<string> {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const mac = process.platform === 'darwin' && process.arch === 'arm64';
  assert.ok(mac || (process.platform === 'linux' && process.arch in linuxDigests), 'Unsupported server host');
  const digest = mac ? macDigest : linuxDigests[process.arch as keyof typeof linuxDigests];
  const archive = join(directory, 'server.tgz');
  if (!existsSync(archive)) {
    let url: string, headers = {};
    if (mac) {
      const auth = await fetch('https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/livekit:pull', { signal: AbortSignal.timeout(30_000) });
      assert.ok(auth.ok, 'Registry authentication failed');
      const { token } = await auth.json() as { token: string };
      url = `https://ghcr.io/v2/homebrew/core/livekit/blobs/sha256:${digest}`;
      headers = { Authorization: `Bearer ${token}` };
    } else url = `https://github.com/livekit/livekit/releases/download/v1.13.11/livekit_1.13.11_linux_${process.arch === 'x64' ? 'amd64' : 'arm64'}.tar.gz`;
    const response = await fetch(url, { headers, signal: AbortSignal.timeout(90_000) });
    assert.ok(response.ok, 'Server download failed');
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.equal(createHash('sha256').update(bytes).digest('hex'), digest, 'Server checksum mismatch');
    writeFileSync(archive, bytes, { mode: 0o600 });
  }
  assert.equal(createHash('sha256').update(readFileSync(archive)).digest('hex'), digest, 'Server checksum mismatch');
  await command('tar', ['-xzf', archive, '-C', directory, ...(mac ? ['--strip-components=3', 'livekit/1.13.11/bin/livekit-server'] : ['livekit-server'])]);
  return join(directory, 'livekit-server');
}
/** Local credentials never appear in process arguments or logs. The first join creates the room. */
export async function startServer(binary: string, directory: string, port?: number) {
  mkdirSync(directory, { recursive: true, mode: 0o700 }); chmodSync(directory, 0o700);
  const key = randomBytes(16).toString('hex'), secret = randomBytes(32).toString('hex');
  const room = randomBytes(16).toString('hex');
  const signalPort = port ?? await unusedPort(), tcpPort = await unusedPort(), udpPort = await unusedPort('udp');
  const config = join(directory, 'server.json');
  writeFileSync(config, JSON.stringify({ port: signalPort,
    rtc: { tcp_port: tcpPort, udp_port: udpPort, use_external_ip: false, enable_loopback_candidate: true },
    keys: { [key]: secret }, logging: { level: 'error' } }), { mode: 0o600 });
  const owner = fork(fileURLToPath(new URL('./server-owner.ts', import.meta.url)), [], { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  const ownerFile = join(directory, 'server-owner.json');
  const exited = once(owner, 'exit');
  let pid: number | undefined;
  const close = async () => {
    if (owner.connected) owner.disconnect();
    await deadline(12_000, 'Server owner shutdown', () => exited);
    rmSync(ownerFile, { force: true }); rmSync(config, { force: true });
  };
  try {
    writeFileSync(ownerFile, JSON.stringify({ pid: owner.pid }), { mode: 0o600 });
    const message = once(owner, 'message');
    owner.send({ binary, config });
    const result = await deadline(5000, 'Server spawn', () => Promise.race([message, exited.then(() => { throw Error('Server exited'); })]));
    pid = (result[0] as { pid: number }).pid;
    const url = `ws://127.0.0.1:${signalPort}`;
    await deadline(12_000, 'Server health', async () => {
      while (true) {
        assert.equal(owner.exitCode, null, 'Server exited before ready');
        if (await fetch(url.replace('ws:', 'http:'), { signal: AbortSignal.timeout(1000) }).then(r => r.ok, () => false)) break;
        await delay(100);
      }
      // Let a bind failure reach the supervisor; an unrelated HTTP listener cannot qualify it.
      await delay(100); assert.equal(owner.exitCode, null, 'Server failed to bind');
    });
    return { url, pid, room, close, abort: () => { if (owner.connected) owner.disconnect(); },
      alive: () => owner.exitCode === null && owner.signalCode === null,
      credentials(identity: string) {
        const part = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
        const data = part({ alg: 'HS256', typ: 'JWT' }) + '.' + part({ iss: key, sub: identity,
          exp: Math.floor(Date.now() / 1000) + 3600, video: { roomJoin: true, room, canPublish: true, canSubscribe: true } });
        return { url, token: data + '.' + createHmac('sha256', secret).update(data).digest('base64url') };
      } };
  } catch (error) { await close(); throw error; }
}
