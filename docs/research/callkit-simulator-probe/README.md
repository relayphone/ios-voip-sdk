# CallKit simulator probe

Instrumented probe used on October 20, 2026 to measure genuine CallKit in the iOS 27.0 simulator (build 24A434, Xcode 27.1 27A9275, macOS 27.0.1, iPhone 17 Pro device type). It drives real `CXProvider`, `CXCallController` and `CXCallObserver` objects and writes an ordered JSON trace. The [runtime plan](../2026-10-20-callkit-simulator-runtime-plan.md) interprets the results.

| File                                              | Contents                                                                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `main.swift`                                      | Probe app. `PROBE_MODE` unset runs the full scenario; `audio`, `hooks`, `suppress` and `semantics` run focused ones |
| `timeouts.swift`                                  | Default `timeoutDate` of each action class and availability of newer action classes                                 |
| `inject.m`                                        | Constructor-only dylib used to verify `DYLD_INSERT_LIBRARIES` injection                                             |
| `2026-10-20-sim-ios27-full-scenario.jsonl`        | Full scenario trace (incoming, call waiting, merge, outgoing, errors, answer deadline, unanswered)                  |
| `2026-10-20-sim-ios27-callservicesd-excerpts.log` | `callservicesd` lines showing the UI-host disconnect, audio activation failure and IDS timeouts                     |
| `2026-10-20-sim-ios27-objc-surface.jsonl`         | Selectors and ivars of the CallKit classes the runtime would interpose                                              |
| `project.yml`                                     | XcodeGen spec for the signed device build                                                                           |
| `2026-10-20-iphone13-ios27-full-scenario.jsonl`   | Same full scenario on the iPhone 13, with a 70 s answer-deadline wait                                               |
| `2026-10-20-iphone13-ios27-call-waiting.jsonl`    | Hold, swap, merge, ungroup and two-call end on the iPhone 13                                                        |
| `2026-10-20-iphone13-ios27-answer-rules.jsonl`    | Answering a waiting call, End & Accept, failed start and remote-end reasons on the iPhone 13                        |
| `2026-10-20-iphone13-ios27-failures.jsonl`        | Failed answer, failed mute and an end action never completed (suspended after 31 s)                                 |

Reproduce with a dedicated simulator:

```bash
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -swift-version 5 -parse-as-library -O main.swift -o Probe.app/Probe -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker probe.entitlements
```

Copy `Info.plist` into `Probe.app`, sign with `codesign -s - --force Probe.app`, install with `xcrun simctl install`, then launch with `xcrun simctl launch --console-pty <udid> dev.callkitsim.probe`. Prefix environment variables with `SIMCTL_CHILD_` to reach the app.

The embedded `application-identifier` entitlement matters. Without it `callservicesd` refuses the call source ("a CXXPCCallSource couldn't be created") and then aborts on the app's first controller request (`-[__NSDictionaryM setObject:forKeyedSubscript:]: key cannot be nil`). Xcode-built apps always carry the entitlement.

The same probe also ran on the iPhone 13 (iOS 27.0, 24A5355q), built from `project.yml` with XcodeGen and automatic signing under the `dev.callkitsim.probe` App ID in team `85A9MS6428`:

```bash
xcodebuild -project CallKitProbe.xcodeproj -scheme Probe -destination 'id=<device udid>' -allowProvisioningUpdates build
```

Install it with `xcrun devicectl device install app`, then launch with `xcrun devicectl device process launch --console`, prefixing variables with `DEVICECTL_CHILD_`. `PROBE_MODE=semantics` with `PROBE_SECTIONS=waiting,waiting2,failures,starts,remote` runs the call-waiting and failure scenarios. Device traces are the `2026-10-20-iphone13-*.jsonl` files. Keep the phone awake during a run: once no call holds audio, a locked phone suspends the probe, which cut the `failures` trace short at 31 s.

## Later evidence (same day)

| Folder                       | Contents                                                                                                                                                                                                                                                                               |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `runtime-spike/`             | Runtime prototype (`CKSimRuntime.m`, `CKSimPush.m`, `CKSimBootstrap.c`), the WebRTC media probe and the LiveCommunicationKit probe, plus raw logs in `runs/`: genuine and runtime full scenarios, push with shadow report, media A/B, LiveCommunicationKit A/B, hooks and manual audio |
| `device-system-ui/`          | XCUITest that operates the genuine call UI on the iPhone 13, test-side traces, app-side traces and the extracted accessibility identifiers                                                                                                                                             |
| `apns-real/`                 | Real sandbox APNs experiments E1–E6b: APNs responses (HTTP 200, apns-id), the Phone-topic probe's trace, and `send.sh`, which reads the certificate and token from private local files and prints neither                                                                              |
| `ci-github-run-39481703479/` | Summaries, environment and traces from GitHub's `macos-26` and `macos-15` runners ([run](https://github.com/ziahamza/callkit-simulator/actions/runs/39481703479), branch `discovery/ci-simulator-probe`)                                                                               |
| `provider-routing/`          | October 21: which of several `CXProvider`s in one process receives each action, on the iPhone 13 (iOS 27.0). Eight scenarios, one launch each; see its README. |

Inject the runtime into an unmodified simulator app with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<CKSimRuntime.dylib> SIMCTL_CHILD_CKSIM_ENABLED=1`, adding `CKSIM_LATENCY=device` for device-like report latency, `CKSIM_SHADOW=1` for shadow reports and `CKSIM_PUSH_AFTER=<seconds>` with `CKSimPush.dylib` for a synthetic VoIP push. For every launch path, set `DYLD_INSERT_LIBRARIES` (appending to any existing value), `CKSIM_BUNDLE_IDS`, `CKSIM_RUNTIME` and `CKSIM_ENABLED` in the simulator's launchd with `xcrun simctl spawn <udid> launchctl setenv`, and restore them afterwards.
