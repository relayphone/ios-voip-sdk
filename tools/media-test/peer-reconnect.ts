import { randomUUID } from 'node:crypto';
import { deadline } from './fixture-runtime.ts';
import type { MediaClock } from '../../expo/src/testing/types.ts';

export interface PeerReconnectObservation {
  readonly id: string;
  readonly clock: MediaClock;
  readonly requestedAtMs: number;
  reconnectingAtMs?: number;
  reconnectedAtMs?: number;
  requestCompletedAtMs?: number;
  readonly publicationSidsBefore: readonly string[];
  publicationSidsAfter?: readonly string[];
}
interface ReconnectPort {
  available(): boolean;
  publications(): string[];
  request(): Promise<void>;
  subscribe(reconnecting: () => void, reconnected: () => void): () => void;
}
/** A failed transport attempt permanently retires control; late FFI completions cannot become a new attempt. */
export class PeerReconnect {
  private state: 'idle' | 'running' | 'failed' = 'idle';
  private observation: PeerReconnectObservation | undefined;
  private readonly port: ReconnectPort;
  private readonly clock: MediaClock;
  private readonly within: (operation: () => Promise<void>) => Promise<void>;
  constructor(port: ReconnectPort, clock: MediaClock,
    within = (operation: () => Promise<void>) => deadline(10_000, 'Peer media reconnect', operation)) {
    this.port = port; this.clock = clock; this.within = within;
  }
  async run(): Promise<void> {
    if (this.state !== 'idle' || !this.port.available()) throw Error('Peer cannot reconnect');
    this.state = 'running';
    const row: PeerReconnectObservation = { id: randomUUID(), clock: { ...this.clock },
      requestedAtMs: performance.now(), publicationSidsBefore: [...this.port.publications()] };
    this.observation = row;
    let active = true;
    const recovered = Promise.withResolvers<void>();
    const unsubscribe = this.port.subscribe(
      () => { if (active) row.reconnectingAtMs ??= performance.now(); },
      () => {
        if (!active) return;
        row.reconnectedAtMs ??= performance.now();
        row.publicationSidsAfter = [...this.port.publications()];
        recovered.resolve();
      });
    try {
      await this.within(async () => {
        await this.port.request();
        if (!active) return;
        row.requestCompletedAtMs = performance.now();
        await recovered.promise;
        if (row.reconnectingAtMs === undefined || !this.port.available())
          throw Error('Peer did not complete the requested reconnect');
      });
      this.state = 'idle';
    } catch (error) {
      this.state = 'failed';
      throw error;
    } finally { active = false; unsubscribe(); }
  }
  /** Includes incomplete attempts on error and never exposes mutable internal arrays. */
  evidence(): PeerReconnectObservation | null {
    const row = this.observation;
    return row ? { ...row, clock: { ...row.clock }, publicationSidsBefore: [...row.publicationSidsBefore],
      ...(row.publicationSidsAfter ? { publicationSidsAfter: [...row.publicationSidsAfter] } : {}) } : null;
  }
}
