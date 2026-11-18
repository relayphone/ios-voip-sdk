import assert from 'node:assert/strict';
import type { NativeJourneyReply } from './native-journey.ts';
import { bindNativeVideoReceiver, bindNativeVideoSource, readNativeSyntheticVideo } from './native-synthetic-video.ts';
import { readNativeVideoEvidence, type NativeVideoEvent } from './native-video-evidence.ts';
import { assessBoundVideo, hostVideoBoundary, type VideoClockBracket, type VideoReceipt, type VideoSourceReceipt } from './video-observation.ts';

export const appParticipant = 'example';

export function readVideoSnapshot(reply: NativeJourneyReply, bracket: VideoClockBracket, fixture: string) {
  const sdk = readNativeVideoEvidence(reply), media = readNativeSyntheticVideo(reply, fixture);
  assert.equal(bracket.clockID, sdk.clockId, 'Foreign video event clock');
  assert.equal(bracket.nativeMs, reply.observedAtMs, 'Stale video clock sample');
  return { reply, bracket, sdk, media };
}
export type VideoSnapshot = ReturnType<typeof readVideoSnapshot>;
type Boundary = { event: NativeVideoEvent; sample: VideoSnapshot };
type Terminal = Boundary & { actionAtMs: number; operation: 'stop' | 'hold' };

function nativeReceipt(snapshot: VideoSnapshot, source: VideoSourceReceipt, epoch: number, terminal?: Terminal): VideoReceipt {
  const receiver = bindNativeVideoReceiver(snapshot.media, source);
  const attached = receiver.lifecycle.find(e => e.kind === 'receiverAttached');
  assert.ok(attached, 'Native video receiver did not attach');
  const { publication } = source;
  const events: VideoReceipt['events'] = [{ kind: 'attached', atMs: attached.atUs / 1000 }];
  for (const action of snapshot.media.actions) {
    if (action.kind === 'roomDisconnected' && terminal?.operation === 'stop' ||
        action.kind === 'remoteUnpublished' && action.publication === publication) {
      events.push({ kind: 'unpublished', atMs: action.atMs });
    }
    if (action.kind === 'roomReconnecting' ||
        action.kind === 'remotePublished' && action.publication !== publication && action.atMs > attached.atUs / 1000 ||
        action.kind === 'receiverDetached' && action.publication === publication) {
      events.push({ kind: 'failed', atMs: action.atMs });
    }
  }
  return {
    clockID: snapshot.media.clockID,
    scope: { fixture: snapshot.media.fixture, direction: 1, epoch, participant: source.participant, publication },
    startedAtMs: attached.atUs / 1000, observedAtMs: receiver.observedAtUs / 1000, events, overflow: false,
    ticks: receiver.lifecycle.filter(e => e.kind === 'receiverHeartbeat').map(e => e.atUs / 1000),
    arrivals: receiver.arrivals.map(a => ({
      atMs: a.atUs / 1000, mediaTimestampUs: a.mediaTimestampNs === null ? '' : String(a.mediaTimestampNs / 1000),
      image: { kind: a.classification, marker: a.marker ?? undefined,
        y: { ...a.y, sample: [...a.y.sample] },
        u: a.u && { ...a.u, sample: [...a.u.sample] }, v: a.v && { ...a.v, sample: [...a.v.sample] } },
    })),
  };
}

/** Both directions use the same frozen gates, retaining each receiver's own clock. */
export function assessJourneyVideo(
  snapshot: VideoSnapshot, enable: Boundary, epoch: number, downlink: VideoSourceReceipt,
  uplink?: VideoReceipt, terminal?: Terminal,
) {
  const { event, sample } = enable;
  const clock = sample.bracket.hostClockID;
  assert.ok(clock === snapshot.bracket.hostClockID && clock === downlink.clockID &&
    (uplink === undefined || clock === uplink.clockID) &&
    (terminal === undefined || clock === terminal.sample.bracket.hostClockID) &&
    sample.sdk.clockId === snapshot.sdk.clockId &&
    (terminal === undefined || snapshot.sdk.clockId === terminal.sample.sdk.clockId), 'Foreign journey clock');
  const enabledOnHost = hostVideoBoundary(event.atMs, sample.bracket);
  const endedOnHost = terminal && hostVideoBoundary(terminal.event.atMs, terminal.sample.bracket);
  const receiver = nativeReceipt(snapshot, downlink, epoch, terminal);
  const down = assessBoundVideo(receiver, downlink, {
    participant: downlink.participant, publication: downlink.publication, afterCounter: 0,
    sourceAnchorMs: enabledOnHost.latest, anchor: { earliest: event.atMs, latest: event.atMs },
    terminal: terminal && endedOnHost ? {
      earliest: terminal.event.atMs, latest: terminal.event.atMs, sourceBoundaryMs: Math.max(endedOnHost.earliest, terminal.actionAtMs),
      // The far end suppresses its own publication when initiating the terminal command.
      publicationAtOrAfterMs: terminal.actionAtMs - terminal.sample.bracket.receivedMs + terminal.sample.bracket.nativeMs,
      operation: terminal.operation,
    } : undefined,
  });
  if (uplink === undefined) return { down, receiver };
  // The source ledger was captured after the snapshot request was sent. Later host
  // callbacks could belong to a frame generated after that ledger was read.
  const source = bindNativeVideoSource(snapshot.media, epoch, uplink, appParticipant);
  const upEnd = source.stoppedAtUs === undefined ? snapshot.bracket.sentMs : uplink.observedAtMs;
  assert.ok(upEnd >= uplink.startedAtMs && upEnd <= uplink.observedAtMs, 'Unobserved uplink snapshot cut');
  const upReceipt = { ...uplink, observedAtMs: upEnd,
    arrivals: uplink.arrivals.filter(a => a.atMs <= upEnd),
    ticks: uplink.ticks.filter(t => t <= upEnd),
    events: uplink.events.filter(e => e.atMs <= upEnd),
  };
  const ledger = snapshot.media.epochs.find(e => e.epoch === epoch)!;
  assert.ok(ledger.anchorAtUs / 1000 >= event.atMs, 'Source epoch predates its SDK event');
  const up = assessBoundVideo(upReceipt, source, {
    participant: appParticipant, publication: source.publication, afterCounter: ledger.afterCounter,
    sourceAnchorMs: event.atMs, anchor: enabledOnHost,
    terminal: terminal && endedOnHost ? {
      ...endedOnHost, sourceBoundaryMs: terminal.event.atMs, stopAtOrAfterMs: terminal.event.atMs,
      operation: terminal.operation,
    } : undefined,
  });
  return { up, down, source, receiver };
}

export function assertRemoteProducer(snapshot: VideoSnapshot, epoch: number, publication: string, event: NativeVideoEvent) {
  const original = snapshot.media.epochs.find(e => e.epoch === epoch);
  const source = original?.source;
  assert.ok(event.kind === 'ended' && event.hasVideo && original?.publication === publication &&
    source?.stoppedAtUs !== undefined && source.stoppedAtUs >= event.atMs * 1000 &&
    source.finalEpoch === epoch && source.finalCounter === source.generated.at(-1)?.counter &&
    source.pacingTaskJoined && source.postStopCaptureRejects > 0 &&
    source.generated.every(m => m.sourceTimeUs <= event.atMs * 1000), 'Missing final remote-end producer boundary');
  return original;
}

export const remoteUplinkCoverage = Object.freeze({ verdict: 'unexercised', reason: 'single far-end peer' } as const);
