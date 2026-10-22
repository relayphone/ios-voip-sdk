# iOS SDK example

This Expo SDK 58 app uses the SDK's public conversation API: state and token
hooks, a demonstration handler, incoming reports, join, connected reports, hold,
resume and end. It owns no `ConversationManager` or `CXProvider`. The SDK starts
its sole client and PushKit service during native launch, before JavaScript.
The screen also shows native module loading and runtime activation, with loading,
error and retry states. The example handler accepts requests locally; production
apps provide signaling and media. No media adapter is demonstrated in M1.

The example enables the default calling app entitlement and observes the public
`dialRequest` event, displaying its destination and audio/video capability.
Requests do not place calls automatically. See [system dial requests](../Expo/M3-dial-requests.md)
for eligibility, cold launch buffering and custom scene forwarding. Native M3
acceptance remains pending.

Install and build the package from repository root:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm run typecheck
```

The repository and example share a single npm workspace installation. The example
depends on `ios-voip-sdk` through `file:..`; Metro watches the repository and resolves
that package to the same source checkout. Keep the shared React and React Native
installation visible when changing Metro configuration.

Generate and build only iOS. Regenerate the ignored native project after the Expo
58 upgrade so the scene lifecycle replaces the legacy app delegate window setup:

```sh
npm run prebuild --workspace ios-voip-sdk-example -- --clean
npm exec --workspace ios-voip-sdk-example -- expo run:ios --configuration Release --device "$EXAMPLE_SIMULATOR_UDID"
```

Set `EXAMPLE_SIMULATOR_UDID` to a newly created simulator owned by your run, and
delete that simulator afterwards. Release mode bundles JavaScript so launch does
not depend on a Metro development server. Native projects, Pods and local Expo
state are ignored. Configure the app's deployment target through
`expo-build-properties` in `app.json`; the pod also requires iOS 17.4.

Expo 58 generates `SceneDelegate.swift` and a `UIApplicationSceneManifest`, creates
the window from its `UIWindowScene`, and preserves autolinked Expo subscribers and
the React Native factory. This is Expo's supported fix for the iOS 27 scene
lifecycle requirement. See the [migration guide](https://github.com/expo/fyi/blob/main/ios-scene-lifecycle.md)
and [supported platform/toolchain versions](https://docs.expo.dev/versions/v58.0.0/).

The app uses iOS semantic colors, a scrollable safe area, text scaling and native
buttons. iPhone/iPad, Dark Mode and large-text visual checks remain pending.

## Acceptance fixtures

**Measured for this slice:** the package builds, the example typechecks against
this worktree's public declarations, Swift grammar parsing passes, and
`python3 discovery/check_sdk_m1.py` passes eight offline control groups containing
two positive three-case fixture variants and 29 tamper cases. The local dependency symlink
points to another worktree's M0 package, so this slice's example typecheck uses a
temporary TypeScript path mapping; it does not modify shared dependencies.
**Proposed:** the combined native build and M1 journeys await source-bound runs.
These host controls do not claim simulator or device qualification.

`SDK_M0_ACCEPTANCE=1` preserves the M0 incoming/ring/join/end journey. Its small
Swift handler exists only in that mode. It uses the SDK client; the legacy trace
labels `idle`, `joined`, `paused` and `left` map to real client projections
`ringing`, `connected`, `held` and `ended`. They are not an additional LCK delegate.
The retained `sdk.managerCreated` marker records binding to the SDK-owned client;
the fixture never creates another manager.

`SDK_M1_CASE` selects one automated example-only case:

| Case               | Journey                                                                                                                                                                                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `journey`          | Inject a required VoIP invitation through the runtime's registered PushKit callback; observe ringing in public snapshots/hooks; verify event-ID and server-call-ID deduplication; join, report connected, hold, resume and end through the public TypeScript API. |
| `cold-launch`      | Native launch injects the push and submits join with no handler. JS verifies the native pending action in both its initial snapshot and hook, attaches the handler, and completes the call.                                                                       |
| `unhandled-expiry` | Keep the handler absent. Observe the actual platform deadline, then require the default failure policy to remove the call without connecting.                                                                                                                     |

The `VoIPExampleJourney` native module and synthetic injection are excluded from
the distributed package. `simulatePush` is guarded to simulator builds and calls
`CKSimInjectPush`; it does not bypass the SDK's PushKit shim or reporting policy.
Only controlled identifiers, state, deadlines and booleans enter fixture traces.
Token values and caller/payload data are never recorded. A token hook returning
`null` is a valid observation, not a claim of APNs registration.

The runner opts in with `SDK_M1_ACCEPTANCE=1` and retains all three cases under
the M0 evidence directory's `m1/` folder. `SDK_M1_RUN_ID`, `SDK_M0_RUN_ID` and
`CKSIM_RUN_ID` must share the manifest run ID. Each
`sdk-m1-<case>.receipt.json` binds its console trace and copied
`sdk-m1-<case>.runtime.jsonl` through `traceSHA256` and `journalSHA256`.
`discovery/sdk_m1_conformance.py` first requires the entire strict M0 source,
installed-product, bootstrap and cleanup proof, then checks the nested journeys,
provider ownership, PushKit/report correlation, handler results and cold policy.
LCK deadline bounds come from the four committed iPhone traces. A lost asynchronous
push/report association is a failing result; the gate does not substitute a
foreground report or weaken correlation to make it pass.

Cold cases wait for native pending state before mounting public state hooks. An
explicit `m1.subscriptionsStarting` checkpoint distinguishes cold hydration from a
live event that arrived after subscription. Both the native pending trace and
Expo relay retain milliseconds. Deadline comparison permits one millisecond of
trace precision and rejects a changed deadline on attachment. Expiry follows the original remaining
interval rather than a new timer derived from JS startup. An expected rejection
of the native join request during the no-handler expiry case is retained as
evidence; it is not counted as an unrelated fixture error.
