import { VideoPeer } from './video-peer.ts';
import { AudioFrame, AudioSource, AudioStream, ConnectionState, LocalAudioTrack, Room, RoomEvent, SimulateScenarioKind, TrackKind, TrackPublishOptions, TrackSource } from '@livekit/rtc-node';
import { createMarker, emissionSamples } from '../../expo/src/testing/marker.ts';
import type { PCMCapture } from './marker-evidence.ts';
import { setTimeout as delay } from 'node:timers/promises';
import { receiverStatistics, senderAudioStatistics } from './receiver-statistics.ts';
import { HOST_RECEIVER_STATS_POLL_MS, type TransportSnapshot } from './transport.ts';
import { deadline } from './fixture-runtime.ts';
import { PeerLifecycle } from './peer-lifecycle.ts';
import { PeerReconnect } from './peer-reconnect.ts';
import type { HarnessAction } from './harness.ts';

interface SenderFrame {
  offsetSamples: number;
  submittedAtMs: number;
  queuedBeforeMs: number;
  acceptedAtMs?: number;
}

interface SenderPacing {
  markerId: string;
  publication: string;
  startedAtMs: number;
  frames: SenderFrame[];
  rtp: { observedAtMs: number; streams: ReturnType<typeof senderAudioStatistics> }[];
  droppedFrames: number;
  droppedRtpRows: number;
}

/** One real far-end participant; observations remain independent of publication control. */
export class MediaPeer {
  private room = new Room();
  private videoPeer?: VideoPeer;
  private videoOpening = false;
  private readonly source: AudioSource;
  private audioPublication?: string;
  private running = true;
  private emission: Int16Array | undefined;
  private senderPacing?: SenderPacing;
  private cursor = 0;
  private publishing: Promise<void> | undefined;
  private readers: Promise<void>[] = [];
  private cancelReaders: (() => Promise<void>)[] = [];
  private received: number[] = [];
  private receivedSamples = 0;
  private energy = 0;
  private readerLive = false;
  private readerGeneration = 0;
  private readonly reconnectControl: PeerReconnect;
  private trackAvailable = false;
  private activeTrackSid: string | undefined;
  private readerFailed = false;
  private publicationFailed = false;
  private stopping: Promise<void> | undefined;
  private transport: TransportSnapshot[] = [];
  private captureGeneration = 0;
  private statistics: Promise<void> | undefined;
  private readonly readStatistics: typeof receiverStatistics;
  private readonly captureLimitSamples: number;
  private readonly lifecycle: PeerLifecycle;
  private readonly now: () => number;
  private retiringAudioPublication?: string;

  constructor(readStatistics: typeof receiverStatistics = receiverStatistics, captureSeconds: 3 | 4 = 3,
    audioQueueMs = 100, now = () => performance.now()) {
    this.source = new AudioSource(48_000, 1, audioQueueMs);
    this.readStatistics = readStatistics;
    this.captureLimitSamples = captureSeconds * 48_000;
    this.lifecycle = new PeerLifecycle(now);
    this.now = now;
    this.reconnectControl = new PeerReconnect({
      available: () => this.running && this.status().connected,
      publications: () => [...this.room.localParticipant!.trackPublications.values()]
        .flatMap(publication => publication.sid ? [publication.sid] : []),
      // FULL_RECONNECT asks the real server for LeaveRequest{Reconnect}; the SDK replaces
      // its RtcSession and republishes tracks. Signal-only resume cannot qualify this action.
      request: () => this.room.simulateScenario(SimulateScenarioKind.SIMULATE_FULL_RECONNECT),
      subscribe: (reconnecting, reconnected) => {
        this.room.on(RoomEvent.Reconnecting, reconnecting);
        this.room.on(RoomEvent.Reconnected, reconnected);
        return () => {
          this.room.off(RoomEvent.Reconnecting, reconnecting);
          this.room.off(RoomEvent.Reconnected, reconnected);
        };
      },
    }, this.lifecycle.snapshot().clock);
    this.room.on(RoomEvent.ParticipantConnected, participant => this.lifecycle.record('participantConnected', participant.identity));
    this.room.on(RoomEvent.ParticipantDisconnected, participant => this.lifecycle.record('participantDisconnected', participant.identity));
    this.room.on(RoomEvent.TrackPublished, (publication, participant) => {
      if (publication.kind === TrackKind.KIND_AUDIO) this.lifecycle.record('trackPublished', participant.identity, publication.sid);
    });
    this.room.on(RoomEvent.TrackUnpublished, (publication, participant) => {
      if (publication.kind === TrackKind.KIND_AUDIO) this.lifecycle.record('trackUnpublished', participant.identity, publication.sid);
    });
    this.room.on(RoomEvent.TrackMuted, (publication, participant) => {
      if (publication.kind === TrackKind.KIND_AUDIO) this.lifecycle.record('trackMuted', participant.identity, publication.sid);
    });
    this.room.on(RoomEvent.TrackUnmuted, (publication, participant) => {
      if (publication.kind === TrackKind.KIND_AUDIO) this.lifecycle.record('trackUnmuted', participant.identity, publication.sid);
    });
    this.room.on(RoomEvent.TrackUnsubscribed, track => {
      if (track.sid !== this.activeTrackSid) return;
      this.activeTrackSid = undefined;
      this.trackAvailable = false; this.readerLive = false;
      this.readerGeneration++;
    });
    this.room.on(RoomEvent.TrackSubscribed, track => {
      if (track.kind !== TrackKind.KIND_AUDIO) return;
      if (this.trackAvailable) { this.readerFailed = true; return; }
      this.activeTrackSid = track.sid;
      this.trackAvailable = true; this.readerLive = true;
      const generation = ++this.readerGeneration;
      const reader = new AudioStream(track, 48_000, 1).getReader();
      this.cancelReaders.push(() => reader.cancel());
      this.readers.push((async () => {
        while (this.running) {
          const { done, value: frame } = await reader.read();
          if (done) { if (generation === this.readerGeneration) this.readerLive = false; break; }
          this.lifecycle.receive(frame.data);
          if (generation !== this.readerGeneration) continue;
          for (const sample of frame.data) {
            const value = sample / 32768;
            this.energy += value * value;
            if (this.received.length < this.captureLimitSamples) this.received.push(value);
          }
          this.receivedSamples += frame.data.length;
        }
      })().catch(() => {
        if (generation === this.readerGeneration && this.running) { this.readerFailed = true; this.readerLive = false; }
      }));
    });
  }
  async connect(credentials: { url: string; token: string }): Promise<void> {
    await deadline(30_000, 'Peer connect', () => this.room.connect(credentials.url, credentials.token));
    this.statistics = (async () => {
      while (this.running) {
        const generation = this.captureGeneration;
        const pacing = this.senderPacing;
        try {
          const row = await this.readStatistics(this.room, () => this.receivedSamples, pacing && (stats => {
            if (pacing !== this.senderPacing) return;
            // A room stats report can contain the retired and replacement RTP streams.
            // Keep them separate so the receipt can show which stream advanced.
            if (pacing.rtp.length < 128) pacing.rtp.push({ observedAtMs: this.now(), streams: senderAudioStatistics(stats) });
            else pacing.droppedRtpRows++;
          }));
          const previous = this.transport.at(-1);
          if (this.running && generation === this.captureGeneration && row &&
              (!previous || row.streamID !== previous.streamID || row.timestamp > previous.timestamp)) this.transport.push(row);
        } catch { /* Missing statistics cannot qualify a clean cycle. */ }
        if (this.running) await delay(HOST_RECEIVER_STATS_POLL_MS);
      }
    })();
    await deadline(15_000, 'Peer publish', () => this.publishAudio());
    this.publishing = (async () => {
      while (this.running) {
        const pacing = this.senderPacing;
        let frame: SenderFrame | undefined;
        if (pacing) {
          if (pacing.frames.length < 1200) {
            frame = { offsetSamples: this.cursor, submittedAtMs: this.now(), queuedBeforeMs: this.source.queuedDuration };
            pacing.frames.push(frame);
          } else pacing.droppedFrames++;
        }
        const pcm = this.emission?.slice(this.cursor, this.cursor + 480) ?? new Int16Array(480);
        this.cursor = this.emission ? (this.cursor + 480) % this.emission.length : 0;
        await this.source.captureFrame(new AudioFrame(pcm, 48_000, 1, 480));
        if (frame) frame.acceptedAtMs = this.now();
      }
    })().catch(() => { this.publicationFailed = true; });
  }
  /** Requests a real server-driven media-session rebuild, never an injected connection state. */
  reconnect(): Promise<void> { return this.reconnectControl.run(); }
  /** Incomplete attempts survive errors; recovery still requires a fresh marker gate. */
  reconnectEvidence() { return this.reconnectControl.evidence(); }

  async act(action: HarnessAction): Promise<void> {
    switch (action.type) {
      case 'publish': this.publish(action.markerId, action.observePacing, action.keepQueuedAudio); break;
      case 'hold': this.hold(); break;
      case 'capture': this.beginCapture(); break;
      case 'leave': await this.close(); break;
      case 'reconnect': await this.reconnect(); break;
    }
  }

  private async publishAudio() {
    const participant = this.room.localParticipant;
    if (!participant) throw Error('Peer is unavailable');
    const track = LocalAudioTrack.createAudioTrack('marker', this.source);
    try {
      const publication = await participant.publishTrack(track,
        new TrackPublishOptions({ source: TrackSource.SOURCE_MICROPHONE }));
      if (!publication.sid) throw Error('Missing peer audio publication identity');
      this.audioPublication = publication.sid;
      return publication.sid;
    } catch (error) { await track.close(false); throw error; }
  }

  /** Start a new receiver stream in the same Room while keeping the paced audio source. */
  async renewAudioPublication(observeRetired: (retired: string) => Promise<void>) {
    const retired = await this.retireAudioPublication();
    await observeRetired(retired);
    return this.replaceAudioPublication(retired);
  }

  async retireAudioPublication() {
    const participant = this.room.localParticipant;
    const audio = [...(participant?.trackPublications.values() ?? [])]
      .filter(publication => publication.track instanceof LocalAudioTrack);
    const [previous] = audio;
    if (!this.running || this.retiringAudioPublication || !participant || audio.length !== 1 || !previous?.sid ||
      !(previous.track instanceof LocalAudioTrack)) throw Error('Peer audio publication is unavailable');
    const { sid: retired, track } = previous;
    this.retiringAudioPublication = retired;
    await participant.unpublishTrack(retired, false);
    await track.close(false);
    return retired;
  }

  async replaceAudioPublication(retired: string) {
    if (!this.running || this.retiringAudioPublication !== retired) throw Error('Peer audio publication was not retired');
    const publication = await this.publishAudio();
    if (publication === retired) throw Error('Peer reused the retired audio publication');
    this.retiringAudioPublication = undefined;
    return { retired, publication };
  }

  publish(markerId: string, observePacing = false, keepQueuedAudio = false): void {
    if (!this.status().connected || this.publicationFailed) throw Error('Peer is unavailable');
    this.emission = Int16Array.from(emissionSamples(createMarker(markerId), 48_000, 48_000 / 50 * 51), value => Math.round(value * 32767));
    this.cursor = 0;
    if (!keepQueuedAudio) this.source.clearQueue();
    this.senderPacing = observePacing && this.audioPublication ? {
      markerId, publication: this.audioPublication, startedAtMs: this.now(), frames: [], rtp: [], droppedFrames: 0, droppedRtpRows: 0,
    } : undefined;
  }
  downlinkPacing() {
    const pacing = this.senderPacing;
    return pacing && { ...pacing, observedAtMs: this.now(), sampleRate: 48_000, frameSamples: 480,
      frames: pacing.frames.map(frame => ({ ...frame })), rtp: pacing.rtp.slice() };
  }
  hold(): void { if (!this.running) throw Error('Peer is closed'); this.emission = undefined; this.senderPacing = undefined; this.cursor = 0; this.source.clearQueue(); }
  beginCapture(): void { this.received = []; this.receivedSamples = 0; this.energy = 0; this.transport = []; this.captureGeneration++; }
  capture(): PCMCapture { return { sampleRate: 48_000, channels: [this.received.slice()], formatChanged: false, transport: this.transport.slice() }; }
  /** Survives beginCapture(), so resetting a phase cannot erase teardown evidence. */
  lifecycleObservation() { return this.lifecycle.snapshot(); }
  audioGate(identity: string, trackSid: string, afterMs: number) {
    return this.lifecycle.audioGate(identity, trackSid, afterMs);
  }
  status() {
    return { connected: this.room.connectionState === ConnectionState.CONN_CONNECTED,
      readerLive: this.readerLive && !this.readerFailed, trackAvailable: this.trackAvailable,
      readerFailed: this.readerFailed, publicationFailed: this.publicationFailed,
      activeTrackSid: this.activeTrackSid, receivedSamples: this.receivedSamples, energy: this.energy, rms: this.receivedSamples ? Math.sqrt(this.energy / this.receivedSamples) : null };
  }
  /** One video phase shares this audio peer's authenticated Room and lifetime. */
  async openVideo(fixture: string, clockID: string): Promise<VideoPeer> {
    if (!this.running || !this.status().connected || this.videoOpening) throw Error('Video peer unavailable');
    this.videoOpening = true;
    try {
      await this.videoPeer?.close();
      if (!this.running || !this.status().connected) throw Error('Video peer retired');
      return this.videoPeer = new VideoPeer(this.room, fixture, clockID, this.now);
    } finally { this.videoOpening = false; }
  }
  close(): Promise<void> {
    return this.stopping ??= deadline(10_000, 'Peer cleanup', async () => {
      this.running = false;
      let videoFailed = false;
      try { await this.videoPeer?.close(); } catch { videoFailed = true; }
      await Promise.allSettled(this.cancelReaders.map(cancel => cancel()));
      await Promise.allSettled(this.readers);
      await this.room.disconnect(); await this.source.close(); await this.publishing; await this.statistics;
      if (videoFailed) throw Error('Video cleanup unconfirmed');
    });
  }
}
