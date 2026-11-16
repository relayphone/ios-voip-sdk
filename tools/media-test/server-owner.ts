// Own the server in a separate process: IPC disconnect also runs when the caller is killed.
import { spawn, type ChildProcess } from 'node:child_process';
import { stopChild } from './fixture-runtime.ts';
import type { ServerEvent } from './server-protocol.ts';
let server: ChildProcess | undefined, stopping = false;
const send = (event: ServerEvent) => { if (process.connected) process.send?.(event); };
async function stop(): Promise<void> {
  if (stopping) return;
  stopping = true;
  if (server) await stopChild(server);
  process.exit(0);
}
process.on('disconnect', () => { void stop(); });
for (const signal of ['SIGTERM', 'SIGINT', 'SIGALRM'] as const) process.on(signal, () => { void stop(); });
process.once('message', (message: { binary: string; config: string }) => {
  let diagnostic = '', truncated = false;
  server = spawn(message.binary, ['--dev', '--bind', '127.0.0.1', '--node-ip', '127.0.0.1', '--config', message.config], { stdio: ['ignore', 'ignore', 'pipe'] });
  server.stderr!.setEncoding('utf8');
  server.stderr!.on('data', (chunk: string) => {
    diagnostic += chunk;
    if (diagnostic.length > 8192) { truncated = true; diagnostic = diagnostic.slice(-8192); }
  });
  server.once('spawn', () => send({ type: 'started', pid: server!.pid! }));
  server.once('error', error => {
    send({ type: 'failed', code: null, signal: null, diagnostic: error.message }); void stop();
  });
  // close follows stderr drainage, so a fast exit cannot lose its final diagnostic.
  server.once('close', (code, signal) => {
    if (!stopping) {
      // Discard a truncated first line so it cannot contain a partial credential.
      if (truncated) diagnostic = '[truncated]\n' + (diagnostic.includes('\n') ? diagnostic.slice(diagnostic.indexOf('\n') + 1) : '');
      send({ type: 'failed', code, signal, diagnostic });
      void stop();
    }
  });
});
