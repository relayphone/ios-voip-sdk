import type { ConversationId } from "../conversations/types.ts";

/** Directions are relative to the app, never to the test runner. */
export type MediaDirection = "toDevice" | "fromDevice";
/** A decoded tap does not establish post-mute output. */
export type MediaObservation =
  | { readonly direction: "toDevice"; readonly stage: "decoded" | "output" }
  | { readonly direction: "fromDevice"; readonly stage: "farEnd" };
export interface MediaClock {
  readonly domain: "nativeMonotonic" | "peerMonotonic";
  /** Unique for the lifetime of the observing process. */
  readonly id: string;
}
export interface MediaTestOptions {
  readonly conversationId: ConversationId;
  readonly fixtureId: string;
}
export type MediaCapability = MediaClock & MediaObservation;
export interface MediaPhaseAnchor {
  readonly clock: MediaClock;
  readonly atMs: number;
}
export interface MediaPhase {
  readonly id: string;
  readonly label: string;
  readonly anchors: readonly MediaPhaseAnchor[];
}
export interface MediaMarker {
  readonly id: string;
  readonly profile: "tones-v1";
  readonly slotMs: 20;
  readonly frequencies: readonly number[];
}
export interface MarkerDetection {
  readonly id: string;
  /** Start of the complete marker relative to the first captured sample. */
  readonly offsetSamples: number;
  readonly confidence: number;
}
/** Measurements for one continuous, unmodified capture window; no inferred silence. */
export type MediaReceipt = MediaTestOptions & MediaObservation & {
  readonly schemaVersion: 1;
  readonly phaseId: string;
  readonly clock: MediaClock;
  readonly tap: "active" | "missing";
  readonly startedAtMs: number;
  readonly endedAtMs: number;
  readonly sampleRate: number;
  readonly sampleCount: number;
  readonly frameCount: number;
  readonly overflowFrames: number;
  /** Independent observer liveness checks, including intervals with no incoming PCM. */
  readonly monitorTicks: number;
  /** Longest interval without a live observer check, not a measure of RTP packet loss. */
  readonly maxGapMs: number;
  readonly rms: number;
  readonly peak: number;
  readonly marker: MarkerDetection | null;
}
/** Defaults to output for toDevice, farEnd for fromDevice. */
export type MediaExpectation =
  | { readonly direction: "toDevice"; readonly stage?: "decoded" | "output" }
  | { readonly direction: "fromDevice"; readonly stage?: "farEnd" };
export type ExpectAudioOptions = MediaExpectation & {
  /** Deadline from the acknowledged phase anchor, in milliseconds. */
  readonly within: number;
}
export type ExpectSilenceOptions = MediaExpectation & {
  /** Continuous measured interval from the phase anchor, in milliseconds. */
  readonly for: number;
}
export type MediaReadRequest = MediaTestOptions & MediaObservation & {
  readonly phase: MediaPhase;
  readonly clock: MediaClock;
  readonly marker: MediaMarker;
  readonly expectation: "audio" | "silence";
  readonly durationMs: number;
}
export interface MediaTestResult {
  readonly expectation: "audio" | "silence";
  readonly receipt: MediaReceipt;
  /** Same-clock marker arrival estimate; not acoustic or cross-clock one-way latency. */
  readonly firstAudioAfterPhaseMs: number | null;
}
/** Platform seam: every assertion observes the actual call media, not a second test room. */
export interface MediaTestConnection {
  /** A fresh native/host UUID for every open, including after JavaScript reloads. */
  readonly sessionId: string;
  readonly capabilities: readonly MediaCapability[];
  beginPhase(id: string, label: string, signal: AbortSignal): Promise<MediaPhase>;
  /** Native/host receipts cross an untrusted serialization boundary. */
  read(request: MediaReadRequest, signal: AbortSignal): Promise<unknown>;
  close(): Promise<void>;
}
export interface MediaTestAdapter {
  open(options: MediaTestOptions, signal: AbortSignal): Promise<MediaTestConnection>;
}
export interface MediaTest {
  beginPhase(label: string): Promise<MediaPhase>;
  expectAudio(options: ExpectAudioOptions): Promise<MediaTestResult>;
  expectSilence(options: ExpectSilenceOptions): Promise<MediaTestResult>;
  close(): Promise<void>;
}
