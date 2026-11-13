/** Software-audio testing contract shared by iOS and Android test adapters. */
export type * from "./types.ts";
export { MediaTestError, type MediaTestErrorCode } from "./errors.ts";
export { createMediaTest } from "./session.ts";
export { createMarker, markerSamples, detectMarker } from "./marker.ts";
export { validateMediaReceipt } from "./receipt.ts";
