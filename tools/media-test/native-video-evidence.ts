import type { NativeJourneyReply } from './native-journey.ts';

export interface NativeVideoEvent {
  readonly sequence: number; readonly kind: 'readySnapshot' | 'changed' | 'held' | 'resumed' | 'ended';
  readonly hasVideo: boolean; readonly connected: boolean; readonly source: 'app' | 'server' | null; readonly atMs: number;
}
export interface NativeVideoEvidence {
  readonly clockId: string; readonly observedAtMs: number; readonly hasVideo: boolean | null;
  readonly onHold: boolean | null; readonly connected: boolean; readonly events: readonly NativeVideoEvent[];
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('Invalid native video evidence');
  return value as Record<string, unknown>;
}
function time(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) throw Error('Invalid native video time');
  return value;
}
/** A command acknowledgement alone never supplies a video event or an initial-state anchor. */
export function readNativeVideoEvidence(reply: NativeJourneyReply): NativeVideoEvidence {
  const video = object(object(reply.evidence).video), observedAtMs = time(video.observedAtMs);
  if (typeof video.clockID !== 'string' || video.clockID.toLowerCase() !== reply.clockId ||
      observedAtMs > reply.observedAtMs || (reply.phaseAtMs !== null && observedAtMs < reply.phaseAtMs)) throw Error('Foreign native video clock');
  const hasVideo = video.hasVideo ?? null, onHold = video.onHold ?? null;
  if (!(hasVideo === null || typeof hasVideo === 'boolean') || !(onHold === null || typeof onHold === 'boolean') ||
      (hasVideo === null) !== (onHold === null) || typeof video.connected !== 'boolean' ||
      (video.connected && hasVideo === null) || video.overflow !== false || !Array.isArray(video.events) || video.events.length > 256)
    throw Error('Incomplete native video evidence');
  let previous = 0;
  const events: NativeVideoEvent[] = video.events.map((value: unknown, index: number) => {
    const row = object(value), atMs = time(row.atMs), source = row.source ?? null;
    if (row.sequence !== index + 1 || typeof row.kind !== 'string' || !['readySnapshot', 'changed', 'held', 'resumed', 'ended'].includes(row.kind) ||
        typeof row.hasVideo !== 'boolean' || typeof row.connected !== 'boolean' || atMs < previous || atMs > observedAtMs ||
        (row.kind === 'changed' ? source !== 'app' && source !== 'server' : source !== null)) throw Error('Invalid native video event');
    previous = atMs;
    return Object.freeze({ sequence: index + 1, kind: row.kind as NativeVideoEvent['kind'],
      hasVideo: row.hasVideo, connected: row.connected, source: source as NativeVideoEvent['source'], atMs });
  });
  return Object.freeze({ clockId: reply.clockId, observedAtMs, hasVideo, onHold, connected: video.connected, events: Object.freeze(events) });
}

type Operation = 'prepare' | 'connect' | 'video' | 'command';
type Category = 'cancelled' | 'livekit' | 'url' | 'osStatus' | 'posix' | 'cocoa' | 'other';
export class NativeJourneyFailure extends Error {
  readonly operation: Operation; readonly category: Category; readonly code: number;
  constructor(operation: Operation, category: Category, code: number, context: 'command' | 'attempt') {
    super(`Native journey ${context === 'command' ? 'command rejected' : 'reported failure'}: ${operation}/${category}/${code}`);
    this.operation = operation; this.category = category; this.code = code;
  }
}
/** Only allowlisted enums and a numeric code may appear in the host error. */
export function nativeJourneyFailure(value: unknown, context: 'command' | 'attempt'): Error {
  if (value === undefined) return Error(`Native journey ${context === 'command' ? 'command rejected' : 'reported failure'}`);
  const row = object(value);
  if (typeof row.operation !== 'string' || !['prepare', 'connect', 'video', 'command'].includes(row.operation) ||
      typeof row.category !== 'string' || !['cancelled', 'livekit', 'url', 'osStatus', 'posix', 'cocoa', 'other'].includes(row.category) ||
      typeof row.code !== 'number' || !Number.isSafeInteger(row.code)) throw Error('Invalid native failure code');
  return new NativeJourneyFailure(row.operation as Operation, row.category as Category, row.code, context);
}
