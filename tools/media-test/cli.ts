import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { dispose } from '@livekit/rtc-node';
import { deadline } from './fixture-runtime.ts';
import { parseAction, startHarness } from './harness.ts';

interface Endpoint { port: number; auth: string; pid: number }
const [verb, directoryArgument, actionJSON] = process.argv.slice(2);
const directory = resolve(directoryArgument ?? '.');
const state = join(directory, 'control.json');
async function request(command: string, action?: unknown): Promise<unknown> {
  const { port, auth } = JSON.parse(readFileSync(state, 'utf8')) as Endpoint;
  const response = await fetch(`http://127.0.0.1:${port}/${command}`, { method: 'POST',
    headers: { Authorization: `Bearer ${auth}` }, body: JSON.stringify(action ?? {}), signal: AbortSignal.timeout(15_000) });
  if (!response.ok) throw Error('Harness command failed');
  return response.json();
}
async function serve(): Promise<void> {
  const fixtureId = randomBytes(16).toString('hex');
  const harness = await startHarness(directory, fixtureId);
  const auth = randomBytes(32).toString('hex');
  let stopping: Promise<void> | undefined;
  const http = createServer({ requestTimeout: 5000, headersTimeout: 5000 }, async (req, res) => {
    if (req.headers.authorization !== `Bearer ${auth}` || req.method !== 'POST') { res.writeHead(403).end(); return; }
    try {
      let body = '';
      for await (const chunk of req) { body += chunk; if (body.length > 4096) throw Error('Request too large'); }
      let result: unknown;
      switch (req.url) {
        case '/status': result = harness.status(); break;
        case '/act': await harness.act(parseAction(JSON.parse(body))); result = harness.status(); break;
        case '/observation': result = harness.observation(); break;
        case '/credentials': result = { credentialsFile: harness.credentialsFile('app') }; break;
        case '/stop': res.end(JSON.stringify({ stopped: true })); void stop(); return;
        default: throw Error('Unknown command');
      }
      res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(result));
    } catch { res.writeHead(400).end(JSON.stringify({ error: 'Invalid or failed harness command' })); }
  });
  const stop = () => stopping ??= (async () => {
    const cleanupTimer = setTimeout(() => { harness.abort(); process.exit(124); }, 25_000);
    http.closeAllConnections(); http.close();
    let success = false;
    try { await harness.stop(); await deadline(5000, 'Native disposal', () => dispose()); success = true; }
    finally { clearTimeout(watchdog); clearInterval(ownerWatch); clearTimeout(cleanupTimer); rmSync(state, { force: true }); process.exit(success ? 0 : 1); }
  })();
  const watchdog = setTimeout(() => { harness.abort(); process.exit(124); }, 180_000);
  const runnerPid = Number(actionJSON);
  const ownerWatch = setInterval(() => {
    try { process.kill(runnerPid, 0); } catch { void stop(); }
  }, 250);
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGALRM'] as const) process.once(signal, () => { void stop(); });
  try {
    await new Promise<void>((ok, fail) => { http.once('error', fail); http.listen(0, '127.0.0.1', ok); });
    const address = http.address();
    if (!address || typeof address === 'string') throw Error('No control port');
    writeFileSync(state, JSON.stringify({ port: address.port, auth, pid: process.pid } satisfies Endpoint), { mode: 0o600 });
  } catch { await stop(); }
}
try {
  if (!directoryArgument) throw Error('Use start|status|act|observation|credentials|stop <directory> [JSON action]');
  if (verb === 'serve') await serve();
  else {
    let result: unknown;
    if (verb === 'start') {
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      if (existsSync(state)) throw Error('Harness state exists; stop it before starting');
      const child = spawn(process.execPath, [fileURLToPath(import.meta.url), 'serve', directory, String(process.ppid)], { detached: true, stdio: 'ignore' });
      child.unref();
      let ready = false;
      try {
        for (let i = 0; i < 1800; i++) {
          if (child.exitCode !== null || child.signalCode !== null) throw Error('Harness startup failed');
          if (existsSync(state)) { await request('status'); ready = true; break; }
          await delay(100);
        }
        if (!ready) throw Error('Harness startup timed out');
      } catch (error) { child.kill('SIGTERM'); throw error; }
      result = { directory, status: await request('status') };
    } else if (verb === 'stop') {
      try { result = await request('stop'); }
      catch {
        const lease = join(directory, 'lease.json');
        if (existsSync(state) || existsSync(lease)) {
          const { pid } = JSON.parse(readFileSync(existsSync(state) ? state : lease, 'utf8')) as Endpoint;
          try { process.kill(pid, 0); throw Error('Live harness is not responding'); }
          catch (error) { if (!(error instanceof Error && 'code' in error && error.code === 'ESRCH')) throw error; }
        }
        const ownerFile = join(directory, 'server-owner.json');
        if (existsSync(ownerFile)) {
          const { pid } = JSON.parse(readFileSync(ownerFile, 'utf8')) as Endpoint;
          await deadline(15_000, 'Crashed server cleanup', async () => {
            while (true) { try { process.kill(pid, 0); } catch { break; } await delay(50); }
          });
        }
        rmSync(ownerFile, { force: true }); rmSync(state, { force: true });
        result = { stopped: true };
      }
      for (let i = 0; i < 300 && existsSync(state); i++) await delay(100);
      if (existsSync(state)) throw Error('Harness did not stop');
      rmSync(join(directory, 'lease.json'), { force: true });
      rmSync(join(directory, 'join.json'), { force: true }); rmSync(join(directory, 'server.json'), { force: true });
    } else if (['status', 'act', 'observation', 'credentials'].includes(verb ?? '')) {
      result = await request(verb!, verb === 'act' ? parseAction(JSON.parse(actionJSON ?? 'null')) : undefined);
    } else throw Error('Unknown command');
    console.log(JSON.stringify(result));
  }
} catch { console.log(JSON.stringify({ error: 'Harness command failed; check command and local state' })); process.exitCode = 1; }
