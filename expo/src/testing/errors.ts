import type { MediaReceipt } from "./types.ts";

export type MediaTestErrorCode =
  | "unavailable" | "capability_missing" | "invalid_arguments" | "invalid_receipt"
  | "adapter_failed" | "phase_required" | "closed" | "deadline_exceeded" | "audio_missing" | "audio_leak" | "unobserved";

/** A missing tap is a capability error, never a successful silence assertion. */
export class MediaTestError extends Error {
  override readonly name = "MediaTestError";
  readonly code: MediaTestErrorCode;
  readonly receipt: MediaReceipt | undefined;
  constructor(code: MediaTestErrorCode, message: string, receipt?: MediaReceipt) {
    super(message); this.code = code; this.receipt = receipt;
  }
}
