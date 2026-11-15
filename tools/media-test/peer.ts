import { AudioFrame, AudioSource, AudioStream, ConnectionState, LocalAudioTrack, Room, RoomEvent, TrackKind, TrackPublishOptions, TrackSource } from '@livekit/rtc-node';
import { createMarker, emissionSamples } from '../../expo/src/testing/marker.ts';
import type { PCMCapture } from './marker-evidence.ts';
import { setTimeout as delay } from 'node:timers/promises';
import { receiverStatistics } from './receiver-statistics.ts';
import type { TransportSnapshot } from './transport.ts';
import { deadline } from './fixture-runtime.ts';
import { PeerLifecycle } from './peer-lifecycle.ts';

/** One real far-end participant; observations remain independent of publication control. */
export class MediaPeer {
  private room = new Room();
  private source = new AudioSource(48_000, 1, 100);
  private running = true;
  private emission: Int16Array | undefined;
  private cursor = 0;
  private publishing: Promise<void> | undefined;
  private readers: Promise<void>[] = [];
  private cancelReaders: (() => Promise<void>)[] = [];
  private received: number[] = [];
  private receivedSamples = 0;
  private energy = 0;
  private readerLive = false;
  private trackAvailable = false;
  private readerFailed = false;
  private publicationFailed = false;
  private stopping: Promise<void> | undefined;
  private transport: TransportSnapshot[] = [];
  private captureGeneration = 0;
  private statistics: Promise<void> | undefined;
  private readonly readStatistics: typeof receiverStatistics;
  private readonly lifecycle = new PeerLifecycle();

  constructor(readStatistics: typeof receiverStatistics = receiverStatistics) {
    this.readStatistics = readStatistics;
    this.room.on(RoomEvent.ParticipantConnected, participant => this.lifecycle.record('participantConnected', participant.identity));
    this.room.on(RoomEvent.ParticipantDisconnected, participant => this.lifecycle.record('participantDisconnected', participant.identity));
    this.room.on(RoomEvent.TrackPublished, (publication, participant) => {
      if (publication.kind === TrackKind.KIND_AUDIO) this.lifecycle.record('trackPublished', participant.identity, publication.sid);
    });
    this.room.on(RoomEvent.TrackUnpublished, (publication, participant) => {
      if (publication.kind === TrackKind.KIND_AUDIO) this.lifecycle.record('trackUnpublished', participant.identity, publication.sid);
    });
    this.room.on(RoomEvent.TrackUnsubscribed, () => { this.trackAvailable = false; });
    this.room.on(RoomEvent.TrackSubscribed, track => {
      if (this.trackAvailable) { this.readerFailed = true; return; }
      this.trackAvailable = true; this.readerLive = true;
      const reader = new AudioStream(track, 48_000, 1).getReader();
      this.cancelReaders.push(() => reader.cancel());
      this.readers.push((async () => {
        while (this.running) {
          const { done, value: frame } = await reader.read();
          if (done) { this.readerLive = false; break; }
          this.lifecycle.receive(frame.data);
          for (const sample of frame.data) {
            const value = sample / 32768;
            this.energy += value * value;
            if (this.received.length < 48_000 * 3) this.received.push(value);
          }
          this.receivedSamples += frame.data.length;
        }
      })().catch(() => { this.readerFailed = true; this.readerLive = false; }));
    });
  }
  async connect(credentials: { url: string; token: string }): Promise<void> {
    await deadline(30_000, 'Peer connect', () => this.room.connect(credentials.url, credentials.token));
    this.statistics = (async () => {
      while (this.running) {
        const generation = this.captureGeneration;
        try {
          const row = await this.readStatistics(this.room, () => this.receivedSamples);
          const previous = this.transport.at(-1);
          if (this.running && generation === this.captureGeneration && row &&
              (!previous || row.streamID !== previous.streamID || row.timestamp > previous.timestamp)) this.transport.push(row);
        } catch { /* Missing statistics cannot qualify a clean cycle. */ }
        if (this.running) await delay(100);
      }
    })();
    const options = new TrackPublishOptions(); options.source = TrackSource.SOURCE_MICROPHONE;
    await deadline(15_000, 'Peer publish', () => this.room.localParticipant!.publishTrack(LocalAudioTrack.createAudioTrack('marker', this.source), options));
    this.publishing = (async () => {
      while (this.running) {
        const pcm = this.emission?.slice(this.cursor, this.cursor + 480) ?? new Int16Array(480);
        this.cursor = this.emission ? (this.cursor + 480) % this.emission.length : 0;
        await this.source.captureFrame(new AudioFrame(pcm, 48_000, 1, 480));
      }
    })().catch(() => { this.publicationFailed = true; });
  }
  publish(markerId: string): void {
    if (!this.status().connected || this.publicationFailed) throw Error('Peer is unavailable');
    this.emission = Int16Array.from(emissionSamples(createMarker(markerId), 48_000, 48_000 / 50 * 51), value => Math.round(value * 32767));
    this.cursor = 0; this.source.clearQueue();
  }
  hold(): void { if (!this.running) throw Error('Peer is closed'); this.emission = undefined; this.cursor = 0; this.source.clearQueue(); }
  beginCapture(): void { this.received = []; this.receivedSamples = 0; this.energy = 0; this.transport = []; this.captureGeneration++; }
  capture(): PCMCapture { return { sampleRate: 48_000, channels: [this.received.slice()], formatChanged: false, transport: this.transport.slice() }; }
  /** Survives beginCapture(), so resetting a phase cannot erase teardown evidence. */
  lifecycleObservation() { return this.lifecycle.snapshot(); }
  status() {
    return { connected: this.room.connectionState === ConnectionState.CONN_CONNECTED,
      readerLive: this.readerLive && !this.readerFailed, trackAvailable: this.trackAvailable,
      readerFailed: this.readerFailed, publicationFailed: this.publicationFailed,
      receivedSamples: this.receivedSamples, energy: this.energy, rms: this.receivedSamples ? Math.sqrt(this.energy / this.receivedSamples) : null };
  }
  close(): Promise<void> {
    return this.stopping ??= deadline(10_000, 'Peer cleanup', async () => {
      this.running = false;
      await Promise.allSettled(this.cancelReaders.map(cancel => cancel()));
      await Promise.allSettled(this.readers);
      await this.room.disconnect(); await this.source.close(); await this.publishing; await this.statistics;
    });
  }
}
