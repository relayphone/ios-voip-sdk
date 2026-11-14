import { execFile, type ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { createSocket } from 'node:dgram';
import { createServer } from 'node:net';
import { promisify } from 'node:util';

const execute = promisify(execFile);
/** Keep the publisher/receiver event loop running while simulator commands execute. */
export async function command(file: string, args: readonly string[], timeout = 120_000): Promise<string> {
  const { stdout } = await execute(file, args, { encoding: 'utf8', timeout, killSignal: 'SIGKILL' });
  return stdout.trim();
}
export async function deadline<T>(milliseconds: number, label: string, operation: () => Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([Promise.resolve().then(operation), new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} exceeded ${milliseconds} ms`)), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}
export async function unusedPort(protocol: 'tcp' | 'udp' = 'tcp'): Promise<number> {
  if (protocol === 'udp') {
    const socket = createSocket('udp4');
    socket.bind(0, '127.0.0.1');
    await once(socket, 'listening');
    const port = socket.address().port;
    await new Promise<void>(resolve => socket.close(resolve));
    return port;
  }
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('No local port');
  await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  return address.port;
}
/** Await actual process exit; a later fixture must never reuse a still-running server. */
export async function stopChild(child: ChildProcess, grace = 5000): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  child.kill('SIGTERM');
  try { await deadline(grace, 'Server shutdown', () => exited); }
  catch {
    child.kill('SIGKILL');
    await deadline(5000, 'Server kill', () => exited);
  }
}
