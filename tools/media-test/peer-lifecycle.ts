import { randomUUID } from 'node:crypto';

export type PeerLifecycleKind = 'participantConnected' | 'participantDisconnected' | 'trackPublished' | 'trackUnpublished' | 'trackMuted' | 'trackUnmuted';
export interface PeerLifecycleEvent {
  readonly kind: PeerLifecycleKind;
  readonly identity: string;
  readonly trackSid?: string;
  readonly atMs: number;
  readonly receivedSamples: number;
}
/** Independent far-end events and PCM after teardown; absence of PCM is never silence. */
export class PeerLifecycle {
  private readonly clock = { domain: 'peerMonotonic' as const, id: randomUUID() };
  private events: PeerLifecycleEvent[] = [];
  private dropped = 0;
  private receivedSamples = 0;
  private publications = new Map<string, { seen: boolean; tracks: Set<string>; disconnected: boolean }>();
  private terminal?: { identity: string; atMs: number; receivedSamples: number; samples: number[]; overflowSamples: number };
  private readonly now: () => number;
  constructor(now = () => performance.now()) { this.now = now; }
  record(kind: PeerLifecycleKind, identity: string, trackSid?: string): void {
    const event = { kind, identity, ...(trackSid ? { trackSid } : {}), atMs: this.now(), receivedSamples: this.receivedSamples };
    if (this.events.length === 256) { this.dropped++; return; }
    this.events.push(event);
    const state = this.publications.get(identity) ?? { seen: false, tracks: new Set<string>(), disconnected: false };
    this.publications.set(identity, state);
    if (kind === 'participantConnected') state.disconnected = false;
    if (kind === 'trackPublished' && trackSid) { state.seen = true; state.tracks.add(trackSid); }
    if (kind === 'trackUnpublished' && trackSid) state.tracks.delete(trackSid);
    if (kind === 'participantDisconnected') state.disconnected = true;
    // Require all observed audio publications to leave, and the participant itself to leave.
    if (state.disconnected && state.seen && state.tracks.size === 0 && !this.terminal)
      this.terminal = { identity, atMs: event.atMs, receivedSamples: this.receivedSamples, samples: [], overflowSamples: 0 };
  }
  receive(samples: Int16Array): void {
    this.receivedSamples += samples.length;
    if (!this.terminal) return;
    const remaining = Math.max(0, 48_000 * 3 - this.terminal.samples.length);
    for (const sample of samples.subarray(0, remaining)) this.terminal.samples.push(sample / 32768);
    this.terminal.overflowSamples += Math.max(0, samples.length - remaining);
  }
  snapshot() {
    return { clock: { ...this.clock }, observedAtMs: this.now(), droppedEvents: this.dropped,
      receivedSamples: this.receivedSamples, events: this.events.map(row => ({ ...row })),
      afterDisconnect: this.terminal ? { identity: this.terminal.identity, startedAtMs: this.terminal.atMs,
        receivedSamplesAtStart: this.terminal.receivedSamples, overflowSamples: this.terminal.overflowSamples,
        sampleRate: 48_000, channels: [this.terminal.samples.slice()] } : null };
  }
}
