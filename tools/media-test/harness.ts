import { mkdirSync, chmodSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { MediaPeer } from './peer.ts';
import { startPeerProcess } from './peer-process.ts';
import { serverBinary, startServer, type ServerVideoUpdate } from './server.ts';
import type { NativeJourneyBudget } from './native-journey.ts';

export type HarnessAction = { type: 'publish'; markerId: string; observePacing?: true; keepQueuedAudio?: true } |
  { type: 'hold' } | { type: 'capture' } | { type: 'leave' } | { type: 'reconnect' };
export interface JoinCredentials { url: string; token: string }
export interface PeerOptions { captureSeconds?: 3 | 4; audioQueueMs?: number }

async function startHarnessWithPeer<P extends { close(): Promise<void> }>(directory: string, fixtureId: string,
  connect: (credentials: JoinCredentials, serverPid: number) => Promise<P>) {
  mkdirSync(directory, { recursive: true, mode: 0o700 }); chmodSync(directory, 0o700);
  const lease = join(directory, 'lease.json');
  writeFileSync(lease, JSON.stringify({ pid: process.pid }), { flag: 'wx', mode: 0o600 });
  let server: Awaited<ReturnType<typeof startServer>>;
  try { server = await startServer(await serverBinary(directory), directory); }
  catch (error) { rmSync(lease); throw error; }
  let peer: P;
  try { peer = await connect(server.credentials('far-end'), server.pid); }
  catch (error) { await server.close(); rmSync(lease, { force: true }); throw error; }
  let stopped: Promise<void> | undefined;
  const stop = () => stopped ??= (async () => { try { await peer.close(); } finally { await server.close(); rmSync(lease, { force: true }); rmSync(join(directory, 'join.json'), { force: true }); } })();
  const receiverStatus = (state: ReturnType<MediaPeer['status']>) => ({
    fixtureId, serverAlive: server.alive(), serverPid: server.pid, ...state, connected: server.alive() && state.connected,
  });
  const assertRunning = () => { if (stopped) throw Error('Harness is stopped'); };
  const harness = {
    fixtureId,
    credentials(identity: string): JoinCredentials { return server.credentials(identity); },
    credentialsFile(identity: string): string {
      const file = join(directory, 'join.json');
      writeFileSync(file, JSON.stringify(server.credentials(identity)), { mode: 0o600 }); return file;
    },
    async updateVideo(update: Omit<ServerVideoUpdate, 'fixtureId'>, budget: NativeJourneyBudget) {
      assertRunning();
      await server.updateVideo({ ...update, fixtureId }, budget);
    },
    abort: () => server.abort(), stop,
  };
  return { harness, peer, receiverStatus, assertRunning };
}

/** Owns one local server/room and one far-end participant. stop() is safe to repeat. */
export async function startHarness(directory: string, fixtureId: string, options: PeerOptions = {}) {
  const { harness, peer, receiverStatus, assertRunning } = await startHarnessWithPeer(directory, fixtureId, async credentials => {
    const { MediaPeer } = await import('./peer.ts');
    const peer = new MediaPeer(undefined, options.captureSeconds, options.audioQueueMs);
    try { await peer.connect(credentials); }
    catch (error) { await peer.close(); throw error; }
    return peer;
  });
  const status = () => receiverStatus(peer.status());
  return {
    ...harness,
    status,
    async openVideo(clockID: string) { assertRunning(); return peer.openVideo(fixtureId, clockID); },
    async renewAudioPublication(observeRetired: (retired: string) => Promise<void>) {
      assertRunning();
      return peer.renewAudioPublication(observeRetired);
    },
    downlinkPacing: () => peer.downlinkPacing(),
    audioLifecycle: () => peer.lifecycleObservation(),
    observation: () => ({ receiver: status(), capture: peer.capture(), lifecycle: peer.lifecycleObservation(), reconnect: peer.reconnectEvidence() }),
    async act(action: HarnessAction): Promise<void> {
      assertRunning();
      await peer.act(action);
    },
  };
}

export async function startIsolatedHarness(directory: string, fixtureId: string, options: PeerOptions = {}) {
  const { harness, peer, receiverStatus, assertRunning } = await startHarnessWithPeer(directory, fixtureId,
    (credentials, serverPid) => startPeerProcess(credentials, options, serverPid));
  return {
    ...harness,
    async status() { return receiverStatus(await peer.status()); },
    async openVideo(clockID: string) { assertRunning(); return peer.openVideo(fixtureId, clockID); },
    async renewAudioPublication(observeRetired: (retired: string) => Promise<void>) {
      assertRunning();
      return peer.renewAudioPublication(observeRetired);
    },
    downlinkPacing: peer.downlinkPacing,
    audioLifecycle: peer.lifecycle,
    async observation() {
      const observation = await peer.observation();
      return { ...observation, receiver: receiverStatus(observation.receiver) };
    },
    receiverWindows: peer.receiverWindows,
    silence: peer.silence,
    heldSilence: peer.heldSilence,
    async act(action: HarnessAction) { assertRunning(); await peer.act(action); },
    abort() { peer.abort(); harness.abort(); },
  };
}
export type IsolatedHarness = Awaited<ReturnType<typeof startIsolatedHarness>>;

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
