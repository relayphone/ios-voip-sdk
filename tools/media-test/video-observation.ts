import { randomUUID } from 'node:crypto';
import { inspectVideoImage, videoIdentity, type VideoImage, type VideoMarker } from './video-marker.ts';
export const videoGates = Object.freeze({ width: 160, height: 120, fps: 10, firstMs: 3000, gapMs: 1600, minimumFPS: 3, drainMs: 800, windowMs: 1000 });
export interface VideoScope { fixture: string; direction: 0 | 1; epoch: number; participant: string; publication: string }
export interface VideoArrival { atMs: number; mediaTimestampUs: string; image: VideoImage }
export interface VideoReceipt { clockID: string; scope: VideoScope; startedAtMs: number; observedAtMs: number;
  arrivals: VideoArrival[]; ticks: number[]; events: {kind: 'attached' | 'unpublished' | 'eos' | 'failed'; atMs: number}[]; overflow: boolean }
/** Bounded synchronous metadata capture. No video buffers survive receive(). */
export class VideoObservation {
  readonly clockID = randomUUID();
  private readonly startedAtMs: number;
  private arrivals: VideoArrival[] = []; private ticks: number[] = [];
  private events: VideoReceipt['events'] = []; private overflow = false;
  readonly scope: VideoScope;
  private readonly now: () => number;
  constructor(scope: VideoScope, now = () => performance.now()) {
    this.now = now;
    videoIdentity({ ...scope, counter: 0, sourceTimeUs: 0 });
    if (!scope.participant || !scope.publication) throw Error('Missing video subscription identity');
    this.scope = Object.freeze({ ...scope });
    this.startedAtMs = now(); this.record('attached');
  }
  private append<T>(rows: T[], value: T) { if (rows.length < 4096) rows.push(value); else this.overflow = true; }
  tick() { this.append(this.ticks, this.now()); }
  record(kind: VideoReceipt['events'][number]['kind']) { this.append(this.events, { kind, atMs: this.now() }); }
  receive(data: Uint8Array, width: number, height: number, timestampUs: bigint) {
    const atMs = this.now(); const image = inspectVideoImage(data, width, height);
    this.append(this.arrivals, { atMs, mediaTimestampUs: timestampUs.toString(), image });
  }
  receipt(): VideoReceipt { return structuredClone({ clockID: this.clockID, scope: this.scope, startedAtMs: this.startedAtMs,
    observedAtMs: this.now(), arrivals: this.arrivals, ticks: this.ticks, events: this.events, overflow: this.overflow }); }
}
/** Bounds a native clock sample by the original host command send/receive, refreshed at transitions. */
export interface VideoClockBracket { hostClockID: string; clockID: string; nativeMs: number; sentMs: number; receivedMs: number }
export interface VideoSourceReceipt { participant: string; publication: string; clockID: string; generated: VideoMarker[]; stoppedAtUs?: number;
  finalCounter?: number | null; finalEpoch?: number; pacingTaskJoined: boolean; postStopCaptureRejects: number; skippedTicks: number; rejectedSubmissions: number }
export function hostVideoBoundary(nativeMs: number, bracket: VideoClockBracket) {
  if (![nativeMs, bracket.nativeMs, bracket.sentMs, bracket.receivedMs].every(n => Number.isFinite(n) && n >= 0) ||
      bracket.receivedMs < bracket.sentMs || nativeMs > bracket.nativeMs || !bracket.clockID) throw Error('Invalid video clock bracket');
  return { earliest: bracket.sentMs + nativeMs - bracket.nativeMs, latest: bracket.receivedMs + nativeMs - bracket.nativeMs };
}
/** Independently validates decoded identities; stats/publish acknowledgements cannot satisfy any gate. */
export function assessVideo(receipt: VideoReceipt, source: VideoSourceReceipt, options: {
  participant: string; publication: string; nativeAnchorMs: number; bracket: VideoClockBracket; afterCounter: number; terminal?: VideoClockBracket; nativeBoundaryMs?: number;
}) {
  if (!Number.isSafeInteger(options.afterCounter) || options.afterCounter < 0 || options.afterCounter > 0xffffffff) throw Error('Invalid video counter fence');
  if (options.participant !== receipt.scope.participant || options.publication !== receipt.scope.publication || source.participant !== options.participant || source.publication !== options.publication) throw Error('Video subscription mismatch');
  if (options.bracket.hostClockID !== receipt.clockID || (options.terminal && options.terminal.hostClockID !== receipt.clockID)) throw Error('Host video clock mismatch');
  if (source.clockID !== options.bracket.clockID || (options.terminal && source.clockID !== options.terminal.clockID)) throw Error('Video clock mismatch');
  if (!!options.terminal !== (options.nativeBoundaryMs !== undefined)) throw Error('Missing confirmed terminal anchor');
  if (source.stoppedAtUs !== undefined && (!Number.isSafeInteger(source.stoppedAtUs) || source.stoppedAtUs < 0)) throw Error('Invalid source boundary');
  const anchor = hostVideoBoundary(options.nativeAnchorMs, options.bracket);
  const scope = receipt.scope, originals = new Set(source.generated.map(videoIdentity)), seen = new Set<string>();
  let corrupt = 0, foreign = 0, duplicate = 0, contentFree = 0, postBoundary = 0;
  const fresh: VideoArrival[] = [], matched: VideoArrival[] = [];
  let previousArrival = receipt.startedAtMs;
  for (const arrival of receipt.arrivals) {
    if (!Number.isFinite(arrival.atMs) || arrival.atMs < previousArrival || arrival.atMs > receipt.observedAtMs) throw Error('Invalid video arrival time');
    previousArrival = arrival.atMs;
    if (arrival.image.kind === 'contentFree') { contentFree++; continue; }
    const m = arrival.image.marker;
    if (arrival.image.kind !== 'source' || !m) { corrupt++; continue; }
    if (options.nativeBoundaryMs !== undefined && m.fixture.toLowerCase() === scope.fixture.toLowerCase() && m.direction === scope.direction && m.epoch === scope.epoch && (m.sourceTimeUs > options.nativeBoundaryMs * 1000 || m.counter > (source.finalCounter ?? -1))) postBoundary++;
    if (arrival.image.y.width !== videoGates.width || arrival.image.y.height !== videoGates.height || m.fixture.toLowerCase() !== scope.fixture.toLowerCase() || m.direction !== scope.direction || m.epoch !== scope.epoch || !originals.has(videoIdentity(m))) { foreign++; continue; }
    matched.push(arrival);
    if (seen.has(videoIdentity(m))) { duplicate++; continue; } seen.add(videoIdentity(m));
    if (m.sourceTimeUs >= options.nativeAnchorMs * 1000 && m.counter > options.afterCounter && arrival.atMs >= anchor.earliest) fresh.push(arrival);
  }
  const end = options.terminal && options.nativeBoundaryMs !== undefined ? hostVideoBoundary(options.nativeBoundaryMs, options.terminal) : undefined;
  const on = fresh.filter(a => !end || a.atMs < end.earliest), windows: number[] = [];
  const onEnd = end?.earliest ?? receipt.observedAtMs;
  if (on.length) for (let t = on[0]!.atMs; t + videoGates.windowMs <= onEnd; t += videoGates.windowMs)
    windows.push(on.filter(a => a.atMs >= t && a.atMs < t + videoGates.windowMs).length);
  const times = on.map(a => a.atMs).concat(on.length ? [onEnd] : []);
  const gapMs = Math.max(0, ...times.slice(1).map((t, i) => t - times[i]! + .001));
  const firstMs = on[0] ? on[0].atMs - anchor.earliest + .001 : null;
  const coverage = [receipt.startedAtMs, ...receipt.ticks, receipt.observedAtMs];
  const healthy = receipt.events.some(e => e.kind === 'attached') && !receipt.events.some(e => e.kind === 'failed') &&
    coverage.every((t, i) => Number.isFinite(t) && (!i || t >= coverage[i - 1]! && t - coverage[i - 1]! <= videoGates.drainMs));
  const drainMs = end ? Math.max(0, ...matched.filter(a => a.atMs >= end.earliest).map(a => a.atMs - end.earliest + .001)) : null;
  const producer = source.stoppedAtUs !== undefined && source.finalCounter === source.generated.at(-1)?.counter && source.finalEpoch === scope.epoch &&
    source.pacingTaskJoined === true && Number.isSafeInteger(source.postStopCaptureRejects) && source.postStopCaptureRejects > 0 &&
    options.nativeBoundaryMs !== undefined && source.stoppedAtUs >= options.nativeBoundaryMs * 1000 && source.generated.every(m => m.sourceTimeUs <= options.nativeBoundaryMs! * 1000);
  const terminal = !!end && producer && receipt.observedAtMs >= end.latest + videoGates.drainMs &&
    receipt.events.some(e => e.kind === 'unpublished' && e.atMs >= end.earliest) && drainMs! <= videoGates.drainMs;
  const validSource = source.generated.length > 0 && source.generated.length <= 4096 && source.generated.every((m, i) =>
    m.fixture.toLowerCase() === scope.fixture.toLowerCase() && m.direction === scope.direction && m.epoch === scope.epoch &&
    (!i || m.counter > source.generated[i - 1]!.counter && m.sourceTimeUs >= source.generated[i - 1]!.sourceTimeUs));
  const eosObserved = !receipt.events.some(e => e.kind === 'eos' && (!end || e.atMs < end.earliest || !receipt.events.some(row => row.kind === 'unpublished')));
  const integrity = validSource && eosObserved && !receipt.overflow && !corrupt && !foreign && !postBoundary && healthy;
  const onPassed = integrity && firstMs !== null && firstMs <= videoGates.firstMs && gapMs <= videoGates.gapMs && windows.length > 0 && windows.every(fps => fps >= videoGates.minimumFPS);
  return { sourceStopLagMs: options.nativeBoundaryMs !== undefined && source.stoppedAtUs !== undefined ? source.stoppedAtUs / 1000 - options.nativeBoundaryMs : null, firstMs, gapMs, windows, drainMs, corrupt, foreign, duplicate, contentFree, postBoundary, healthy,
    onPassed, offPassed: onPassed && terminal };
}
