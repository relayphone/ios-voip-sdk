import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { dispose } from '@livekit/rtc-node';
import { MediaPeer } from './peer.ts';
import { monitorReceiver, ReceiverObservationError, type ReceiverWindow } from './peer-window.ts';
import { observeSilence, SilenceObservationError } from './silence-window.ts';
import type { HarnessAction, JoinCredentials, PeerOptions } from './harness.ts';
import type { VideoPeer } from './video-peer.ts';

interface SilenceOptions { deadlineMs: number; durationMs: number; gapLimitMs: number }

function peerOperations() {
  let peer: MediaPeer;
  let video: VideoPeer | undefined;
  let videoId = 0;
  let serverPid: number;
  let now: () => number;
  const status = () => {
    const state = peer.status();
    let serverAlive = true;
    try { process.kill(serverPid, 0); } catch { serverAlive = false; }
    return { ...state, connected: state.connected && serverAlive };
  };
  const currentVideo = (id: number) => {
    assert.ok(video && id === videoId, 'Video peer retired');
    return video;
  };
  const timing = { now: () => now(), pause: (ms: number) => delay(ms) };
  async function silence(options: SilenceOptions, isCurrent = () => true) {
    try {
      const windows = await observeSilence(() => {
        const state = status();
        return { ...state, trackAvailable: state.trackAvailable && isCurrent(), samples: state.receivedSamples };
      }, options, timing);
      return { windows, reason: undefined };
    } catch (error) {
      if (!(error instanceof SilenceObservationError)) throw error;
      return { windows: error.windows, reason: error.reason };
    }
  }
  let stopped: Promise<void> | undefined;
  const close = () => stopped ??= (async () => {
    try { await peer?.close(); } finally { await dispose(); }
  })();
  return {
    async connect(credentials: JoinCredentials, options: PeerOptions, pid: number, parentOriginMs: number) {
      assert.ok(!peer, 'Peer already started');
      serverPid = pid;
      now = () => Number(process.hrtime.bigint()) / 1e6 - parentOriginMs;
      peer = new MediaPeer(undefined, options.captureSeconds, options.audioQueueMs, now);
      await peer.connect(credentials);
    },
    status,
    lifecycle: () => peer.lifecycleObservation(),
    observation: () => ({ receiver: status(), capture: peer.capture(), lifecycle: peer.lifecycleObservation() }),
    downlinkPacing: () => peer.downlinkPacing(),
    async act(action: HarnessAction) { await peer.act(action); },
    retireAudio: () => peer.retireAudioPublication(),
    replaceAudio: (retired: string) => peer.replaceAudioPublication(retired),
    async receiverWindows(deadlineMs: number) {
      const windows: { phase: 'window-1' | 'window-2' | 'window-3'; window: ReceiverWindow }[] = [];
      for (const phase of ['window-1', 'window-2', 'window-3'] as const) {
        try {
          for (const window of await monitorReceiver(status, { deadlineMs }, timing)) windows.push({ phase, window });
        } catch (error) {
          if (!(error instanceof ReceiverObservationError)) throw error;
          for (const window of error.windows) windows.push({ phase, window });
          return { windows, failure: { phase, reason: error.reason, health: error.health, gapMs: error.gapMs } };
        }
      }
      return { windows, failure: undefined };
    },
    silence: (options: SilenceOptions) => silence(options),
    async heldSilence(identity: string, trackSid: string, actionAtMs: number, drainMs: number, options: SilenceOptions) {
      const gate = () => peer.audioGate(identity, trackSid, actionAtMs);
      let muted = gate();
      while (muted?.kind !== 'trackMuted') {
        assert.ok(now() < options.deadlineMs, 'Far-end held audio publication was not muted by the deadline');
        assert.equal(peer.status().activeTrackSid, trackSid, 'Held far-end audio subscription changed');
        await delay(Math.min(20, Math.max(0, options.deadlineMs - now())));
        muted = gate();
      }
      const drainThroughMs = muted.atMs + drainMs;
      while (now() < drainThroughMs) {
        assert.ok(now() < options.deadlineMs, 'Held audio drain exceeded the deadline');
        await delay(Math.min(options.deadlineMs, drainThroughMs) - now());
      }
      const before = status();
      const isCurrent = () => gate() === muted && peer.status().activeTrackSid === trackSid;
      const result = await silence(options, isCurrent);
      return { ...result, muted, drainThroughMs, before, after: status() };
    },
    async openVideo(fixtureId: string, clockID: string) {
      video = await peer.openVideo(fixtureId, clockID);
      return ++videoId;
    },
    observeVideo: (id: number, participant: string, epoch: number) => currentVideo(id).observe(participant, epoch),
    publishVideo: (id: number, epoch: number) => currentVideo(id).publish(epoch),
    holdVideo: (id: number) => currentVideo(id).hold(),
    freezeVideo: (id: number) => currentVideo(id).freeze(),
    stopVideo: (id: number) => currentVideo(id).stop(),
    videoObservation: (id: number) => currentVideo(id).observation(),
    videoSnapshot: (id: number) => {
      const video = currentVideo(id);
      return { up: video.observation(), down: video.sourceReceipt() };
    },
    videoStatus: (id: number) => currentVideo(id).status(),
    close,
  };
}

export type PeerOperations = ReturnType<typeof peerOperations>;
export type PeerCommand = keyof PeerOperations;
export type PeerResult = Awaited<ReturnType<PeerOperations[PeerCommand]>>;
export type PeerRequest = { id: number; command: PeerCommand; args: unknown[] };
export type PeerResponse = { id: number; value: PeerResult } | { id: number; error: Error };

const operations = peerOperations();
process.on('message', async ({ id, command, args }: PeerRequest) => {
  let response: PeerResponse;
  try {
    // SAFETY: The private IPC client types every argument tuple against its command.
    const operation = operations[command] as (...args: unknown[]) => PeerResult | Promise<PeerResult>;
    response = { id, value: await operation(...args) };
  }
  catch (error) { response = { id, error: error instanceof Error ? error : Error(String(error)) }; }
  if (process.connected) process.send?.(response, () => {});
});
process.once('disconnect', async () => {
  try { await operations.close(); process.exit(0); }
  catch { process.exit(1); }
});
