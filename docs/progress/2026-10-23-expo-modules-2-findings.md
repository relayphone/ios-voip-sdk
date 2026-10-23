# Expo Modules 2.0 findings — October 23, 2026

**Measured:** Release, local Xcode 27.1 / Swift 6.4, iPhone 17 Pro / iOS 27.0;
Expo 58.0.17, RN 0.88.0, core 58.0.24, macros 0.22.0. The app/pod minimum is
17.4. [Scaffold #53](https://github.com/ziahamza/ios-voip-sdk/pull/53) and
[records/events #54](https://github.com/ziahamza/ios-voip-sdk/pull/54) are merged;
[their CI](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40006223067) passes.
Threading replay/results are in the [spike workflow](https://github.com/ziahamza/ios-voip-sdk/actions/workflows/spike-expo-modules-2.yml?query=branch%3Aspike%2Fexpo2-threading).

## Thread placement

Classification uses `runtime.isOnJavaScriptThread()`, checked against pthread
identity; a synchronous helper captures main/thread/queue diagnostics inline.
`JS` below is thread `com.facebook.react.runtime.JavaScript` (ID 5279459);
`pool` is queue `com.apple.root.user-initiated-qos.cooperative` (ID 5279491).

| Native/JS observation                                 | Main | Thread or queue                | JS thread |
| ----------------------------------------------------- | ---- | ------------------------------ | --------- |
| Sync `@JS` entry                                      | No   | JS                             | Yes       |
| Default async, before first `await`                   | No   | JS                             | Yes       |
| Default `@JavaScriptActor`, after 20 ms suspension    | No   | pool                           | No        |
| Custom SDK actor, before/after suspension             | No   | pool                           | No        |
| Native `@Event` emission                              | No   | `expo2.spike.background-event` | No        |
| JS event listener (sync native probe inside callback) | No   | JS                             | Yes       |

The SDK command body/state live in `@SDKActor SDKCommands`; the thin async
binding transfers values to that service. Nine calls, including eight concurrent
calls, return unique sequences 1–9. An actor is not a dedicated OS thread.
The default JS actor's inline executor does not pin post-suspension execution;
JSI access needs explicit runtime scheduling, as its [source documents](https://github.com/expo/expo/blob/expo-modules-jsi%4058.0.17/packages/expo-modules-jsi/apple/Sources/ExpoModulesJSI/Runtime/JavaScriptActor.swift#L3).

## Snapshot cost

100 warmups, then 1,000 back-to-back synchronous reads per fixture; nearest-rank
per-read percentiles from `performance.now()`, in microseconds. Batch time includes
loop/timer overhead. Publication/freezing is excluded; these are observations,
not CI performance budgets.

| Conversations | p50 µs | p99 µs | Whole batch ms |
| ------------- | ------ | ------ | -------------- |
| 2             | 0.166  | 0.292  | 0.270          |
| 2,048         | 0.166  | 0.250  | 0.267          |

A frozen JS object is encoded once per version and returned by retained handle;
identity stays stable. Direct `@Record` getters would re-encode O(n) data.
Coalesced native events deliver versions `[3, 4]`; duplicate revisions emit none.
The results file gates CI; screenshots are diagnostic, and simulators/DerivedData
are deleted. No physical-device result is claimed.

**Beta gaps:** typed events need `: Module` (still macro-only exports); direct
noncopyable JSI return types need a copyable envelope around their retained handle.
A `.concurrent` instance writer failed Swift's sending-self check; a default async
binding awaiting a detached value-only task compiles without unchecked conformance.

**Recommendation for #50:** proceed with a thin macro adapter and explicitly
isolated SDK services, preserving the SDK's existing state-isolation decision.
Pass Sendable command data across that boundary; schedule JSI publication on the
runtime, especially after `await`. Keep cached frozen projections and one version
change event. Preserve the 1.0 fallback until the handler/deadline and early
PushKit integration are proven; never make push reporting wait for JS startup.

**Stop:** slices 1–3 are implemented. Handler/AbortSignal, export drift, shared
object events, and early PushKit checks await orchestration review.
