# A0.1 / A1 incoming-report acceptance handoff

**Measured:** the PushKit queue/report-entry correction landed in [PR #28](https://github.com/ziahamza/ios-voip-sdk/pull/28), merged as `cdbf35ff18c0fddfa523d339dfafada574332d08`. The native main-stall fixture landed in [PR #32](https://github.com/ziahamza/ios-voip-sdk/pull/32), merged as `6f58777f3fd16a9dc1378660e49b9011e7653fd6`.

The published local record is pinned to the actually executed source `5808a2000edf16a26b8c776ddd4d47655f133947`, with source-input digest `ccdb609525a1a9a86734f389c9796b74b94eff7f46bdb78f9e7d7f30db0622a4`. Shipping `Sources/` bytes are identical between that source and the merge above.

The [allowlisted receipt](../verification/2026-10-22-native-push-main-stall/native27-5808/receipt.json), [original-row excerpt](../verification/2026-10-22-native-push-main-stall/native27-5808/main-stall-excerpt.json) and [addendum](../verification/2026-10-22-native-push-main-stall/native27-5808/handoff-addendum.md) publish the independently reviewed record. The full private capture remains retained locally. This handoff copies the reviewed packet without rerunning or modifying the measured source.

All six committed cases passed on iOS 27.0, followed by a separate successful read-only full-capture replay. Five cases use in-app push injection: required reporting, a duplicate, deliberately missing/deferred reporting, and optional omission. The missing/deferred delegates retain complete expected strict failures. The sixth case directly invokes the real SDK native-owner delivery body while main is blocked. The real LCK framework reaches the simulator runtime's actual provider-report hook.

During the measured 3.001-second main stall, actual provider entry at runtime-clock 48 ms preceded native return at 2025 ms and stall end at 3020 ms. Successful settlement and the one native completion followed at 3045 ms, with the same canonical SDK UUID/payload. The gate also permits valid early settlement; this run does not establish a general private completion queue.

The one bounded attempt took 129.57 seconds. The owned simulator was shut down and deleted with zero exits, then independently absent from inventory. An extra app terminate returned code 3, matching the retained “found nothing to terminate” diagnostic after the six supervisors had stopped. Inherited launch settings remained unchanged; no launchd mutation, runtime-library injection change, audio action or physical-device operation occurred.

Hosted source-`5808a200` acceptance also passed: [SDK run 39781445339](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39781445339), [runtime run 39781445336](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39781445336) and [release controls 39781445368](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39781445368). The native runs executed on simulator iOS 26.5 with the `ios-27.0` profile; independent read-only artifact replays passed. PR #32 carries the artifact identities, ZIP digests and retained-evidence limits.

This closes the incoming-report simulator acceptance only. It does **not** mark all A0 work complete:

- Native iOS 27 audio-interruption acceptance remains pending on its separate audio candidate.
- Corrected-head physical APNs cold launches, both locked and unlocked, and lock-screen answer-to-activation measurements remain required before beta. This direct callback-body fixture does not deliver APNs or qualify a physical PushKit cold launch.
