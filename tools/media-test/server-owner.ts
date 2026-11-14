// Own the server in a separate process: IPC disconnect also runs when the caller is killed.
import { spawn, type ChildProcess } from 'node:child_process';
import { stopChild } from './fixture-runtime.ts';
let server: ChildProcess | undefined, stopping = false;
async function stop(): Promise<void> {
  if (stopping) return;
  stopping = true;
  if (server) await stopChild(server);
  process.exit(0);
}
process.on('disconnect', () => { void stop(); });
for (const signal of ['SIGTERM', 'SIGINT', 'SIGALRM'] as const) process.on(signal, () => { void stop(); });
process.once('message', (message: { binary: string; config: string }) => {
  server = spawn(message.binary, ['--dev', '--bind', '127.0.0.1', '--node-ip', '127.0.0.1', '--config', message.config], { stdio: 'ignore' });
  server.once('spawn', () => process.send?.({ pid: server!.pid }));
  server.once('error', () => { process.exitCode = 1; void stop(); });
  server.once('exit', () => { if (!stopping) { process.disconnect?.(); void stop(); } });
});
