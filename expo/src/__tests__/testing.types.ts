/* eslint-disable no-void -- Compile-only expressions exercise the testing contract. */
import { createMediaTest, MediaTestError } from "../testing/index.ts";
import type { MediaTest, MediaTestOptions, MediaTestResult, MediaPhase, MediaCapability } from "../testing/index.ts";

declare const media: MediaTest;
declare const options: MediaTestOptions;
declare const result: MediaTestResult;
declare const phase: MediaPhase;
const opened: Promise<MediaTest> = createMediaTest(options);
void opened;
void media.expectAudio({ direction: "toDevice", within: 3000 });
void media.expectAudio({ direction: "toDevice", stage: "decoded", within: 3000 });
void media.expectSilence({ direction: "fromDevice", for: 500 });
// @ts-expect-error Durations use milliseconds, not strings.
void media.expectAudio({ direction: "toDevice", within: "3s" });
// @ts-expect-error Output is observed at the device, not at the far end.
void media.expectSilence({ direction: "fromDevice", stage: "output", for: 500 });
// @ts-expect-error Missing duration cannot establish an observation window.
void media.expectSilence({ direction: "toDevice" });
// @ts-expect-error Results cannot be rewritten by an application.
result.receipt.tap = "active";
// @ts-expect-error Phase clock anchors are immutable.
phase.anchors.push({ clock: { domain: "peerMonotonic", id: "new" }, atMs: 0 });
const decoded: MediaCapability = { direction: "toDevice", stage: "decoded", domain: "nativeMonotonic", id: "native" };
void decoded;
// @ts-expect-error The far end cannot advertise the device's output capability.
const invalid: MediaCapability = { direction: "fromDevice", stage: "output", domain: "peerMonotonic", id: "peer" };
void invalid;
declare const error: MediaTestError;
const errorCode: string = error.code;
void errorCode;
