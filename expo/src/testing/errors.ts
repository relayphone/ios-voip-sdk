export type MediaTestErrorCode =
  | "unavailable" | "capability_missing" | "invalid_arguments" | "invalid_receipt"
  | "adapter_failed" | "phase_required" | "closed" | "deadline_exceeded" | "audio_missing" | "audio_leak";

/** A missing tap is a capability error, never a successful silence assertion. */
export class MediaTestError extends Error {
  readonly name = "MediaTestError";
  readonly code: MediaTestErrorCode;
  constructor(code: MediaTestErrorCode, message: string) { super(message); this.code = code; }
}
