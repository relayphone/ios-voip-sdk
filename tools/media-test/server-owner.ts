// Own the server in a separate process: IPC disconnect also runs when the caller is killed.
import { spawn, type ChildProcess } from 'node:child_process';
import { performance } from 'node:perf_hooks';
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
  const started = performance.now();
  let exitAfterMs: number | undefined;
  const tail = () => {
    let bytes = Buffer.alloc(0), truncated = false;
    return {
      append(chunk: Buffer) {
        truncated ||= bytes.length + chunk.length > 8192;
        bytes = Buffer.concat([bytes, chunk]).subarray(-8192);
      },
      text() {
        const text = bytes.toString('utf8');
        // A cut first line could contain a partial credential or UTF-8 character.
        return truncated ? '[truncated]\n' + (text.includes('\n') ? text.slice(text.indexOf('\n') + 1) : '') : text;
      },
    };
  };
  const stdout = tail(), stderr = tail();
  server = spawn(message.binary, ['--dev', '--bind', '127.0.0.1', '--node-ip', '127.0.0.1', '--config', message.config], { stdio: ['ignore', 'pipe', 'pipe'] });
  server.stdout!.on('data', (chunk: Buffer) => stdout.append(chunk));
  server.stderr!.on('data', (chunk: Buffer) => stderr.append(chunk));
  server.once('exit', () => { exitAfterMs = performance.now() - started; });
  server.once('spawn', () => send({ type: 'started', pid: server!.pid! }));
  server.once('error', error => {
    send({ type: 'failed', code: null, signal: null, stdout: stdout.text(), stderr: error.message, exitAfterMs: performance.now() - started, closeAfterMs: performance.now() - started }); void stop();
  });
  // close follows stdout/stderr drainage, so a fast exit cannot lose its final diagnostic.
  server.once('close', (code, signal) => {
    if (!stopping) {
      send({ type: 'failed', code, signal, stdout: stdout.text(), stderr: stderr.text(),
        exitAfterMs: exitAfterMs ?? performance.now() - started, closeAfterMs: performance.now() - started });
      void stop();
    }
  });
});
