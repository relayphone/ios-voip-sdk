import type { NativeJourneyBudget, NativeJourneyReply } from './native-journey.ts';
import { nativeJourneyFailure } from './native-video-evidence.ts';
import { videoIdentity, type VideoMarker, type VideoPlane } from './video-marker.ts';
import { hostVideoBoundary, type VideoClockBracket, type VideoReceipt, type VideoSourceReceipt } from './video-observation.ts';

function invalid(): never { throw Error('Invalid native synthetic video evidence'); }
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return invalid();
  return value as Record<string, unknown>;
}
function integer(value: unknown, maximum = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0 || value > maximum) return invalid();
  return value;
}
function time(value: unknown, maximum = Number.MAX_VALUE): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > maximum) return invalid();
  return value;
}
function text(value: unknown): string {
  if (typeof value !== 'string' || !value || value.length > 256) return invalid();
  return value;
}
function uuid(value: unknown): string {
  const id = text(value).toLowerCase();
  if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(id)) return invalid();
  return id;
}
function bool(value: unknown): boolean { if (typeof value !== 'boolean') return invalid(); return value; }
function rows(value: unknown, maximum = 4096): unknown[] {
  if (!Array.isArray(value) || value.length > maximum) return invalid();
  return value as unknown[];
}
function choice<const T extends string>(value: unknown, options: readonly T[]): T {
  if (typeof value !== 'string' || !options.includes(value as T)) return invalid();
  return value as T;
}
function marker(value: unknown): VideoMarker {
  const m = object(value);
  const parsed = { fixture: uuid(m.fixture), direction: integer(m.direction, 1) as 0 | 1,
    epoch: integer(m.epoch, 0xffffffff), counter: integer(m.counter, 0xffffffff), sourceTimeUs: integer(m.sourceTimeUs) };
  videoIdentity(parsed); return Object.freeze(parsed);
}
export type NativeVideoPlane = Readonly<Omit<VideoPlane, 'sample'>> & { readonly sample: readonly number[]; readonly stride: number; readonly byteCount: number };
function plane(value: unknown): NativeVideoPlane {
  const p = object(value);
  const signed = (v: unknown) => { if (typeof v !== 'number' || !Number.isSafeInteger(v)) return invalid(); return v; };
  const width = signed(p.width), height = signed(p.height), stride = signed(p.stride), byteCount = integer(p.byteCount);
  const complete = bool(p.complete), minimum = p.minimum == null ? null : integer(p.minimum, 255);
  const maximum = p.maximum == null ? null : integer(p.maximum, 255);
  if (complete ? width <= 0 || width > 1920 || height <= 0 || height > 1080 || stride < width || stride > 16384 ||
      byteCount < stride * height || minimum === null || maximum === null || maximum < minimum : minimum !== null || maximum !== null) return invalid();
  if (typeof p.sample !== 'string' || p.sample.length > 24 || Buffer.from(p.sample, 'base64').toString('base64') !== p.sample) return invalid();
  const sample = [...Buffer.from(p.sample, 'base64')];
  if (sample.length > 16 || sample.length !== Math.min(16, complete ? width * height : byteCount) ||
      (complete && sample.some(n => n < minimum! || n > maximum!))) return invalid();
  return Object.freeze({ width, height, stride, byteCount, complete, minimum, maximum, sample: Object.freeze(sample) });
}
const actionKinds = ['published', 'heldSourceStarted', 'muted', 'stopped', 'receiverAttached', 'receiverDetached',
  'roomDisconnected', 'remotePublished', 'remoteUnpublished', 'remoteUnsubscribed', 'receiverReplaced', 'lateSubscription'] as const;
const lifecycleKinds = ['receiverAttached', 'receiverHeartbeat', 'receiverDetached', 'publicationMuted', 'publicationUnpublished', 'republished'] as const;
export type NativeVideoActionKind = typeof actionKinds[number];
export type NativeVideoLifecycleKind = typeof lifecycleKinds[number];
export interface NativeDecodedVideoArrival {
  readonly atUs: number; readonly marker: VideoMarker | null;
  readonly mediaTimestampNs: number | null; readonly rtpTimestamp: number | null;
  readonly classification: 'source' | 'contentFree' | 'ambiguous';
  readonly y: NativeVideoPlane; readonly u: NativeVideoPlane | null; readonly v: NativeVideoPlane | null;
  readonly bufferType: 'luma' | 'i420' | 'pixelBuffer' | 'unsupported';
}
export interface NativeVideoEpoch {
  readonly epoch: number; readonly publication: string | null; readonly anchorAtUs: number; readonly afterCounter: number;
  readonly source: Omit<VideoSourceReceipt, 'participant' | 'publication' | 'generated'> & { readonly generated: readonly VideoMarker[] };
}
export interface NativeVideoReceiver {
  readonly publication: string; readonly observedAtUs: number; readonly arrivals: readonly NativeDecodedVideoArrival[];
  readonly lifecycle: readonly { kind: NativeVideoLifecycleKind; atUs: number }[]; readonly queueHighWaterMark: number;
}
export interface NativeSyntheticVideoEvidence {
  readonly clockID: string; readonly fixture: string; readonly observedAtMs: number;
  readonly publication: string | null; readonly publicationMuted: boolean | null; readonly roomConnected: boolean;
  readonly remotePublications: readonly string[]; readonly epochs: readonly NativeVideoEpoch[];
  readonly receivers: readonly NativeVideoReceiver[]; readonly actions: readonly { kind: NativeVideoActionKind; atMs: number; publication: string | null }[];
}
/** Reads original evidence only. No SDK event, source order or cross-clock latency is inferred. */
export function readNativeSyntheticVideo(reply: NativeJourneyReply, fixtureID: string): NativeSyntheticVideoEvidence {
  const fixture = uuid(fixtureID), v = object(object(reply.evidence).syntheticVideo);
  const clockID = uuid(v.clockID), observedAtMs = time(v.observedAtMs, reply.observedAtMs);
  if (clockID !== reply.clockId || v.overflow !== false || (reply.phaseAtMs !== null && observedAtMs < reply.phaseAtMs)) return invalid();
  if (v.failure != null) throw nativeJourneyFailure(v.failure, 'attempt');
  const endUs = observedAtMs * 1000;
  if (!Number.isSafeInteger(Math.floor(endUs))) return invalid();
  const publication = v.publicationSID == null ? null : text(v.publicationSID);
  const publicationMuted = v.publicationMuted == null ? null : bool(v.publicationMuted);
  if ((publication === null) !== (publicationMuted === null)) return invalid();
  const epochs = rows(v.epochs, 64).map((value, index): NativeVideoEpoch => {
    const e = object(value), a = object(e.anchor), s = object(e.source), epoch = integer(e.epoch, 64);
    if (epoch !== index + 1 || uuid(a.clockID) !== clockID || uuid(s.clockID) !== clockID ||
        uuid(s.fixture) !== fixture || s.direction !== 0 || s.epoch !== epoch) return invalid();
    const generated = rows(s.generated).map(marker);
    if (!generated.length || generated.some((m, i) => m.fixture !== fixture || m.direction !== 0 || m.epoch !== epoch ||
        m.sourceTimeUs > endUs || (i > 0 && (m.counter <= generated[i - 1]!.counter || m.sourceTimeUs < generated[i - 1]!.sourceTimeUs)))) return invalid();
    const anchorAtUs = integer(a.atUs), afterCounter = integer(a.afterCounter, 4095);
    if (anchorAtUs > endUs || !generated.some(m => m.counter === afterCounter && m.sourceTimeUs <= anchorAtUs) ||
        generated.some(m => m.counter > afterCounter && m.sourceTimeUs < anchorAtUs)) return invalid();
    const skippedTicks = integer(s.skippedTicks, 4096), rejectedSubmissions = integer(s.rejectedSubmissions, generated.length);
    if (integer(s.nextCounter, 4096) !== generated.length + skippedTicks || generated.at(-1)!.counter >= (s.nextCounter as number)) return invalid();
    const stoppedAtUs = s.stoppedAtUs == null ? undefined : integer(s.stoppedAtUs);
    const finalCounter = s.finalCounter == null ? null : integer(s.finalCounter, 4095);
    const finalEpoch = s.finalEpoch == null ? undefined : integer(s.finalEpoch, 64);
    const pacingTaskJoined = bool(s.pacingTaskJoined), postStopCaptureRejects = integer(s.postStopCaptureRejects);
    if (stoppedAtUs === undefined ? finalCounter !== null || finalEpoch !== undefined || postStopCaptureRejects !== 0 :
      stoppedAtUs < generated.at(-1)!.sourceTimeUs || stoppedAtUs < anchorAtUs || stoppedAtUs > endUs || finalCounter !== generated.at(-1)!.counter || finalEpoch !== epoch) return invalid();
    return Object.freeze({ epoch, publication: e.publicationSID == null ? null : text(e.publicationSID), anchorAtUs, afterCounter,
      source: Object.freeze({ clockID, generated: Object.freeze(generated), stoppedAtUs, finalCounter, finalEpoch, pacingTaskJoined, postStopCaptureRejects, skippedTicks, rejectedSubmissions }) });
  });
  if (epochs.slice(0, -1).some(e => e.source.stoppedAtUs === undefined) ||
      new Set(epochs.flatMap(e => e.publication === null ? [] : [e.publication])).size !== epochs.filter(e => e.publication !== null).length) return invalid();
  let priorAction = 0;
  const actions = rows(v.actions).map(value => {
    const a = object(value), atMs = time(a.atMs, observedAtMs);
    if (atMs < priorAction) return invalid(); priorAction = atMs;
    const kind = choice(a.kind, actionKinds);
    if (kind === 'receiverReplaced' || kind === 'lateSubscription') return invalid();
    return Object.freeze({ kind, atMs, publication: a.publicationSID == null ? null : text(a.publicationSID) });
  });
  const decoded = rows(v.receivers, 64).map(value => {
    const r = object(value), o = object(r.observation), observedAtUs = integer(o.observedAtUs);
    if (uuid(o.clockID) !== clockID || observedAtUs > endUs || o.overflow !== false) return invalid();
    let prior = 0;
    const arrivals = rows(o.arrivals).map((value): NativeDecodedVideoArrival => {
      const a = object(value), p = object(a.provenance), atUs = integer(a.atUs);
      if (atUs < prior || atUs > observedAtUs) return invalid(); prior = atUs;
      const y = plane(p.y), u = p.u == null ? null : plane(p.u), v = p.v == null ? null : plane(p.v);
      const bufferType = choice(p.bufferType, ['luma', 'i420', 'pixelBuffer', 'unsupported']);
      const classification = choice(p.classification, ['source', 'contentFree', 'ambiguous']);
      const m = a.marker == null ? null : marker(a.marker);
      const complete = y.complete && (u === null && v === null || u?.complete && v?.complete &&
        u.width === Math.ceil(y.width / 2) && v.width === u.width && u.height === Math.ceil(y.height / 2) && v.height === u.height) && bufferType !== 'unsupported';
      if ((classification === 'source') !== (m !== null) || classification !== 'ambiguous' && !complete) return invalid();
      const sourceGeometry = (y.width === 160 && y.height === 120) || (y.width === 320 && y.height === 240);
      if (classification === 'source' && (!sourceGeometry || y.minimum! > 64 || y.maximum! < 192)) return invalid();
      if (classification === 'contentFree' && (sourceGeometry ||
          [y, u, v].some(p => p !== null && p.maximum! - p.minimum! > 4))) return invalid();
      const mediaTimestampNs = p.mediaTimestampNs == null ? null : p.mediaTimestampNs;
      if (mediaTimestampNs !== null && (typeof mediaTimestampNs !== 'number' || !Number.isSafeInteger(mediaTimestampNs))) return invalid();
      const rtpTimestamp = p.rtpTimestamp == null ? null : integer(p.rtpTimestamp, 0xffffffff);
      return Object.freeze({ atUs, marker: m, classification, y, u, v, bufferType, mediaTimestampNs, rtpTimestamp });
    });
    prior = 0;
    const lifecycle = rows(o.lifecycle).map(value => {
      const e = object(value), atUs = integer(e.atUs);
      if (atUs < prior || atUs > observedAtUs) return invalid(); prior = atUs;
      return Object.freeze({ kind: choice(e.kind, lifecycleKinds), atUs });
    });
    return Object.freeze({ publication: text(r.publicationSID), observedAtUs, arrivals: Object.freeze(arrivals),
      lifecycle: Object.freeze(lifecycle), queueHighWaterMark: integer(o.queueHighWaterMark, 4096) });
  });
  const remotePublications = rows(v.remotePublications, 64).map(text);
  if (new Set(decoded.map(r => r.publication)).size !== decoded.length || new Set(remotePublications).size !== remotePublications.length ||
      publication !== null && !epochs.some(e => e.publication === publication && e.source.stoppedAtUs === undefined)) return invalid();
  return Object.freeze({ clockID, fixture, observedAtMs, publication, publicationMuted, roomConnected: bool(v.roomConnected),
    remotePublications: Object.freeze(remotePublications), epochs: Object.freeze(epochs), receivers: Object.freeze(decoded), actions: Object.freeze(actions) });
}

/** Binds native generation to an independently observed actual participant/publication, never an acknowledgement. */
export function bindNativeVideoSource(native: NativeSyntheticVideoEvidence, epoch: number, receipt: VideoReceipt, participant: string): VideoSourceReceipt {
  const e = native.epochs.find(row => row.epoch === epoch);
  if (!e?.publication || receipt.scope.participant !== participant || receipt.scope.publication !== e.publication ||
      receipt.scope.fixture.toLowerCase() !== native.fixture || receipt.scope.direction !== 0 || receipt.scope.epoch !== epoch) return invalid();
  return structuredClone({ ...e.source, generated: [...e.source.generated], participant, publication: e.publication });
}
/** Selects the actual reverse subscription and checks decoded identities without mapping clock origins. */
export function bindNativeVideoReceiver(native: NativeSyntheticVideoEvidence, source: VideoSourceReceipt): NativeVideoReceiver {
  const receiver = native.receivers.find(r => r.publication === source.publication);
  if (!receiver || source.participant !== 'far-end' || !source.generated.length || source.generated.length > 4096) return invalid();
  uuid(source.clockID);
  const originals = new Set(source.generated.map(videoIdentity));
  if (source.generated.some((m, i) => m.fixture.toLowerCase() !== native.fixture || m.direction !== 1 ||
      m.epoch !== source.generated[0]!.epoch || i > 0 && (m.counter <= source.generated[i - 1]!.counter || m.sourceTimeUs < source.generated[i - 1]!.sourceTimeUs)) ||
      receiver.arrivals.some(a => a.marker !== null && !originals.has(videoIdentity(a.marker)))) return invalid();
  return receiver;
}
/** A fresh mailbox snapshot brackets the original native clock sample with host send/receive times. */
export async function sampleNativeVideoClock(
  mailbox: { request(action: { operation: 'snapshot' }, budget: NativeJourneyBudget): Promise<NativeJourneyReply> },
  budget: NativeJourneyBudget, hostClockID: string, now: () => number = () => performance.now(),
): Promise<{ reply: NativeJourneyReply; bracket: VideoClockBracket }> {
  const host = uuid(hostClockID); budget.signal.throwIfAborted();
  if (!Number.isFinite(budget.deadlineMs)) throw Error('Invalid native video deadline');
  const sentMs = time(now());
  if (sentMs >= budget.deadlineMs) throw Error('Native video snapshot deadline exceeded');
  const reply = await mailbox.request({ operation: 'snapshot' }, budget), receivedMs = time(now());
  budget.signal.throwIfAborted();
  if (receivedMs >= budget.deadlineMs) throw Error('Native video snapshot deadline exceeded');
  const bracket = Object.freeze({ hostClockID: host, clockID: uuid(reply.clockId), nativeMs: time(reply.observedAtMs), sentMs, receivedMs });
  hostVideoBoundary(reply.observedAtMs, bracket);
  return { reply, bracket };
}
