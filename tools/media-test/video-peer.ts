import { LocalVideoTrack, Room, RoomEvent, TrackKind, TrackPublishOptions, TrackSource, VideoBufferType, VideoCodec, VideoFrame, VideoSource, VideoStream, type TrackPublication, type Participant, type RemoteTrackPublication, type RemoteTrack, type RemoteParticipant } from '@livekit/rtc-node';
import { setTimeout as delay } from 'node:timers/promises';
import { videoIdentity, videoLuma, type VideoMarker } from './video-marker.ts';
import { VideoObservation, type VideoReceipt, type VideoSourceReceipt } from './video-observation.ts';
import { deadline } from './fixture-runtime.ts';

/** Uses the existing fixture Room: no additional server or call/session controller. */
export class VideoPeer {
  private source?: VideoSource; private track?: LocalVideoTrack; private sid?: string;
  private pumping?: Promise<void>; private abort?: AbortController; private held = false;
  private generated: VideoMarker[] = []; private counter = 0; private epoch = 0;
  private publishing?: Promise<boolean>; private sourceSID?: string;
  private joined = true; private closing?: Promise<void>; private rejectedSubmissions = 0;
  private stoppedAtUs?: number; private rejected = 0; private skipped = 0; private failed = false;
  private observer?: VideoObservation; private reader?: ReadableStreamDefaultReader<import('@livekit/rtc-node').VideoFrameEvent>;
  private reading?: Promise<void>; private monitor?: ReturnType<typeof setInterval>;
  private failureReported = false;
  private arm?: { participant: string; epoch: number }; private closed = false;
  readonly sourceClockID: string;
  private readonly now: () => number;
  private readonly room: Room; readonly fixture: string;
  constructor(room: Room, fixture: string, clockID: string, now = () => performance.now()) {
    this.room = room; this.fixture = fixture;
    videoIdentity({ fixture, direction: 1, epoch: 0, counter: 0, sourceTimeUs: 0 });
    if (!clockID) throw Error('Missing source clock');
    this.sourceClockID = clockID;
    this.now = now;
    this.room.on(RoomEvent.TrackSubscribed, this.subscribed);
    this.room.on(RoomEvent.TrackUnpublished, this.unpublished);
    this.room.on(RoomEvent.TrackMuted, this.muted);
    this.room.on(RoomEvent.TrackPublished, this.published);
    this.room.on(RoomEvent.Reconnecting, this.reconnecting);
    this.monitor = setInterval(() => {
      this.observer?.tick();
      if (this.closed || !this.room.isConnected) this.observer?.record('failed');
    }, 100);
  }
  /** Arm before publication; one subscription is bound to its actual participant and SID. */
  async observe(participant: string, epoch: number) {
    if (this.closed || !participant || !Number.isSafeInteger(epoch) || epoch < 0 || epoch > 0xffffffff) throw Error('Invalid video observer');
    if (this.arm) throw Error('Video observation already armed');
    this.arm = { participant, epoch };
  }
  private subscribed = (track: RemoteTrack, publication: RemoteTrackPublication, participant: RemoteParticipant) => {
    if (track.kind !== TrackKind.KIND_VIDEO || !this.arm || participant.identity !== this.arm.participant || this.failed) return;
    if (!publication.sid || this.observer || publication.source !== TrackSource.SOURCE_CAMERA) { this.failed = true; this.observer?.record('failed'); return; }
    this.observer = new VideoObservation({ fixture: this.fixture, direction: 0, epoch: this.arm!.epoch,
      participant: participant.identity, publication: publication.sid }, this.now, this.sourceClockID);
    const reader = new VideoStream(track).getReader(); this.reader = reader;
    this.reading = (async () => {
      try {
        while (!this.closed) {
          const { done, value } = await reader.read();
          if (done) { this.observer!.record('eos'); return; }
          // Conversion copies native-owned buffers before the next read; no async analysis queue.
          const frame = value.frame.type === VideoBufferType.I420 ? value.frame : value.frame.convert(VideoBufferType.I420);
          this.observer!.receive(frame.data, frame.width, frame.height, value.timestampUs);
        }
      } catch { this.failed = true; this.observer?.record('failed'); }
    })();
  };
  private reconnecting = () => { this.failed = true; this.observer?.record('failed'); };
  private published = (publication: RemoteTrackPublication, participant: RemoteParticipant) => {
    const scope = this.observer?.scope;
    if (scope && participant.identity === scope.participant && publication.kind === TrackKind.KIND_VIDEO &&
        publication.sid !== scope.publication) this.observer!.record('failed');
  };
  private muted = (publication: TrackPublication, participant: Participant) => {
    const scope = this.observer?.scope;
    if (scope && participant.identity === scope.participant && publication.sid === scope.publication) this.observer!.record('muted');
  };
  private unpublished = (publication: RemoteTrackPublication, participant: RemoteParticipant) => {
    const scope = this.observer?.scope;
    if (scope && participant.identity === scope.participant && publication.sid === scope.publication) this.observer!.record('unpublished');
  };
  observation(): VideoReceipt | undefined {
    if (this.failed && this.observer && !this.failureReported) { this.observer.record('failed'); this.failureReported = true; }
    return this.observer?.receipt();
  }
  /** Start a fresh downlink epoch at the qualified 160×120/10fps profile, VP8, one layer. */
  async publish(epoch: number) {
    if (this.closed || this.source || !Number.isSafeInteger(epoch) || epoch < 0 || epoch > 0xffffffff) throw Error('Invalid video publication');
    this.epoch = epoch; this.source = new VideoSource(160, 120);
    this.track = LocalVideoTrack.createVideoTrack('synthetic-camera', this.source);
    this.capture(); // Resolve dimensions before publishing; this seed is recorded, never fabricated remotely.
    const options = new TrackPublishOptions({ source: TrackSource.SOURCE_CAMERA, videoCodec: VideoCodec.VP8, simulcast: false });
    this.publishing = (async () => {
      const publication = await this.room.localParticipant!.publishTrack(this.track!, options);
      if (!publication.sid) throw Error('Missing video publication identity');
      this.sid = publication.sid; this.sourceSID = publication.sid;
      if (this.closed || this.stoppedAtUs !== undefined) { await this.unpublish(); return false; }
      return true;
    })();
    try {
      const admitted = await deadline(3000, 'Video publication', () => this.publishing!);
      if (!admitted || this.closed || this.stoppedAtUs !== undefined) throw Error('Video publication retired');
    } catch { this.failed = true; this.freeze(); throw Error('Video publication incomplete'); }
    this.abort = new AbortController(); this.joined = false;
    this.pumping = (async () => {
      let next = this.now();
      while (!this.abort!.signal.aborted) {
        while (next + 100 <= this.now()) { this.counter++; this.skipped++; next += 100; }
        this.capture(); next = Math.max(next + 100, this.now() + 100);
        try { await delay(Math.max(0, next - this.now()), undefined, { signal: this.abort!.signal }); }
        catch (error) { if (!this.abort!.signal.aborted) throw error; }
      }
    })().catch(() => { this.failed = true; this.observer?.record('failed'); }).finally(() => { this.joined = true; });
  }
  private capture() {
    if (!this.source || this.stoppedAtUs !== undefined) { this.rejected++; throw Error('Video source stopped'); }
    if (this.generated.length >= 4096 || this.counter > 0xffffffff) throw Error('Video source overflow');
    const marker: VideoMarker = { fixture: this.fixture, direction: 1, epoch: this.epoch, counter: this.counter++, sourceTimeUs: Math.floor(this.now() * 1000) };
    const data = new Uint8Array(160 * 120 * 3 / 2).fill(128); data.set(videoLuma(marker)); this.generated.push(marker);
    try { this.source.captureFrame(new VideoFrame(data, 160, 120, VideoBufferType.I420), BigInt(marker.sourceTimeUs)); }
    catch (error) { this.rejectedSubmissions++; throw error; }
  }
  private async unpublish() {
    const sid = this.sid; if (!sid) return;
    try { await deadline(3000, 'Video unpublish', () => this.room.localParticipant!.unpublishTrack(sid, false)); this.sid = undefined; }
    catch { this.failed = true; throw Error('Video unpublish unconfirmed'); }
  }
  /** Suppress at the actual publication gate while the source continues to advance counters. */
  async hold() {
    if (!this.sid || this.held || this.stoppedAtUs !== undefined) throw Error('Video publication unavailable');
    await this.unpublish(); this.held = true;
  }
  /** Retire generation synchronously before dispatching a terminal SDK action. */
  freeze() { this.stoppedAtUs ??= Math.floor(this.now() * 1000); this.abort?.abort(); }
  private async retire() {
    this.freeze(); await this.pumping;
    if (this.publishing) await deadline(3000, 'Pending video publication', () => this.publishing!);
    await this.unpublish();
  }
  /** Freeze before any await; join pacing and resolve or reject outstanding publication work. */
  async stop(): Promise<VideoSourceReceipt> {
    await this.retire();
    try { this.capture(); } catch { /* Retain the actual post-stop rejection. */ }
    return this.sourceReceipt();
  }
  sourceReceipt(): VideoSourceReceipt {
    if (this.failed) throw Error('Video peer failed');
    return structuredClone({ participant: this.room.localParticipant?.identity ?? '', publication: this.sourceSID ?? '', clockID: this.sourceClockID, generated: this.generated, stoppedAtUs: this.stoppedAtUs,
      finalCounter: this.stoppedAtUs === undefined ? undefined : this.generated.at(-1)?.counter, finalEpoch: this.epoch,
      pacingTaskJoined: this.joined, skippedTicks: this.skipped, rejectedSubmissions: this.rejectedSubmissions, postStopCaptureRejects: this.rejected });
  }
  status() { return { failed: this.failed, held: this.held, publication: this.sid, generated: this.generated.length, skipped: this.skipped }; }
  close(): Promise<void> {
    return this.closing ??= (async () => {
      this.closed = true; this.observer?.record('failed');
      this.room.off(RoomEvent.TrackSubscribed, this.subscribed);
      this.room.off(RoomEvent.TrackUnpublished, this.unpublished);
      this.room.off(RoomEvent.TrackMuted, this.muted);
      this.room.off(RoomEvent.TrackPublished, this.published);
      this.room.off(RoomEvent.Reconnecting, this.reconnecting);
      clearInterval(this.monitor);
      let incomplete = false;
      try { await this.retire(); } catch { incomplete = true; }
      // Disposal always starts, even if unpublish or pending publication did not settle.
      try {
        const results = await deadline(2000, 'Video disposal', () => Promise.allSettled([
          this.reader?.cancel(), this.reading, this.track ? this.track.close() : this.source?.close(),
        ]));
        incomplete ||= results.some(result => result.status === 'rejected');
      } catch { incomplete = true; }
      if (incomplete) throw Error('Video cleanup unconfirmed');
    })();
  }
}
