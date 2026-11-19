import { mkdirSync, chmodSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { MediaPeer } from './peer.ts';
import { serverBinary, startServer, type ServerVideoUpdate } from './server.ts';
import type { NativeJourneyBudget } from './native-journey.ts';

export type HarnessAction = { type: 'publish'; markerId: string } | { type: 'hold' } | { type: 'capture' } | { type: 'leave' } | { type: 'reconnect' };
export interface JoinCredentials { url: string; token: string }
/** Owns one local server/room and one far-end participant. stop() is safe to repeat. */
export async function startHarness(directory: string, fixtureId: string, { captureSeconds }: { captureSeconds?: 3 | 4 } = {}) {
  mkdirSync(directory, { recursive: true, mode: 0o700 }); chmodSync(directory, 0o700);
  const lease = join(directory, 'lease.json');
  writeFileSync(lease, JSON.stringify({ pid: process.pid }), { flag: 'wx', mode: 0o600 });
  let server: Awaited<ReturnType<typeof startServer>>;
  try { server = await startServer(await serverBinary(directory), directory); }
  catch (error) { rmSync(lease); throw error; }
  let peer: MediaPeer;
  try { peer = new MediaPeer(undefined, captureSeconds); }
  catch (error) { await server.close(); rmSync(lease, { force: true }); throw error; }
  let stopped: Promise<void> | undefined;
  const stop = () => stopped ??= (async () => { try { await peer.close(); } finally { await server.close(); rmSync(lease, { force: true }); rmSync(join(directory, 'join.json'), { force: true }); } })();
  try { await peer.connect(server.credentials('far-end')); }
  catch (error) { await stop(); throw error; }
  const status = () => ({ fixtureId, serverAlive: server.alive(), serverPid: server.pid,
    ...peer.status(), connected: server.alive() && peer.status().connected });
  return {
    fixtureId,
    credentials(identity: string): JoinCredentials { return server.credentials(identity); },
    credentialsFile(identity: string): string {
      const file = join(directory, 'join.json');
      writeFileSync(file, JSON.stringify(server.credentials(identity)), { mode: 0o600 }); return file;
    },
    status,
    async openVideo(clockID: string) {
      if (stopped) throw Error('Harness is stopped');
      return peer.openVideo(fixtureId, clockID);
    },
    async renewAudioPublication(observeRetired: (retired: string) => Promise<void>) {
      if (stopped) throw Error('Harness is stopped');
      return peer.renewAudioPublication(observeRetired);
    },
    async updateVideo(update: Omit<ServerVideoUpdate, 'fixtureId'>, budget: NativeJourneyBudget) {
      if (stopped) throw Error('Harness is stopped');
      await server.updateVideo({ ...update, fixtureId }, budget);
    },
    observation: () => ({ receiver: status(), capture: peer.capture(), lifecycle: peer.lifecycleObservation(), reconnect: peer.reconnectEvidence() }),
    async act(action: HarnessAction): Promise<void> {
      if (stopped) throw Error('Harness is stopped');
      switch (action.type) {
        case 'publish': peer.publish(action.markerId); break;
        case 'hold': peer.hold(); break;
        case 'capture': peer.beginCapture(); break;
        case 'leave': await peer.close(); break;
        case 'reconnect': await peer.reconnect(); break;
      }
    },
    abort: () => server.abort(), stop,
  };
}
export type MediaHarness = Awaited<ReturnType<typeof startHarness>>;

/** Validate untrusted CLI/JSON commands before touching native media. */
export function parseAction(value: unknown): HarnessAction {
  if (!value || typeof value !== 'object' || !('type' in value)) throw Error('Invalid action');
  switch (value.type) {
    case 'hold': case 'capture': case 'leave': case 'reconnect': return { type: value.type };
    case 'publish':
      if ('markerId' in value && typeof value.markerId === 'string' && value.markerId.length > 0 && value.markerId.length <= 256)
        return { type: 'publish', markerId: value.markerId };
  }
  throw Error('Invalid action');
}
