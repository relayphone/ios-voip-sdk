# SDK device QA preparation

This fixture builds the canonical Swift SDK and Objective-C platform shim into
one device app. It exercises `VoIPApplication`, `PushService` and the SDK's only
`ConversationClient`. It does not compile the historical CallKit probe or create
another provider, conversation manager or push registry. The simulator engine and
interposition sources are absent from this device target.

The fixture and its diagnostics are enabled only by the `SDK_DEVICE_QA` Swift
condition and C definition. Ordinary package and Expo builds leave those hooks
off. This tooling is preparation; a successful build does not prove APNs delivery,
locked cold launch, incoming UI, audio activation or media flow.

`python3 discovery/check_sdk_device_build.py` checks the builder with synthetic
source trees and mocked native tools. It performs no Xcode build, signing,
installation, launch or APNs request.

## Build only

Use the approved QA app identity and development team from the operator's private
setup. The values below are placeholders; do not add real environment values or
credentials to this document. Use the existing approved signing account and
provisioning setup. The dedicated test device must already be registered.

From the checkout containing the committed SDK and fixture sources:

```sh
export SDK_DEVICE_BUNDLE_ID='your.approved.qa.bundle'
export SDK_DEVICE_TEAM_ID='TEAMID1234'
bash discovery/device/build_sdk.sh ".env/sdk-device-build-$(date -u +%Y%m%dT%H%M%SZ)"
```

XcodeGen and Xcode must already be available. The script generates its spec,
project, entitlements, Info.plist, bridging header and DerivedData inside the
fresh output directory. It uses Swift 6 and iOS 17.4, compiles
`Sources/VoIPSDK/*.swift`, `Sources/VoIPPlatform/*.m`, `SDKDeviceProbe.swift` and
`DeviceQAStorage.swift`, and imports the guarded QA header through
`Sources/VoIPPlatform/include/VoIPPlatform.h`.

The build uses automatic signing with `-allowProvisioningUpdates` and the fixed
`generic/platform=iOS` destination. It does not request device registration,
install or launch an app, run tests, query a device, or send a push. Native tool
calls have deadlines; a timeout fails the build rather than retrying it.

The output must not already exist. Under this checkout's ignored `.env/`, the
script creates private directories with mode `0700`. An output elsewhere must
be a fresh child of an existing, caller-owned directory with mode `0700`.
Generated files use a private umask. Keep the entire output private: the Xcode
project, signing log and decoded provisioning profile can contain local paths,
team information and registered device identifiers. Do not upload them to public
CI artifacts or commit them.

The resulting app is:

```text
<output>/DerivedData/Build/Products/Debug-iphoneos/SDKDeviceProbe.app
```

The script verifies its signature and separately checks the signed app's APNs,
application and team entitlements against the matching development provisioning
profile. Decoded entitlements remain private beside that profile.
`source-build-start.json` and `build-receipt.json` bind the executable
to the committed source inputs; a source change during compilation fails the
receipt. The app's Info.plist carries only the public source commit and source
input hash as `SDKDeviceQASourceCommit` and `SDKDeviceQASourceInputsSHA256`.

## Future operator-run device phase

Use only the dedicated QA device identified in the private operator notes. Keep
its identifier out of checked-in configuration. Installation and launch are
separate manual operations. The phone must be awake and unlocked for development
launch and UI automation; if it is locked, ask the operator to unlock it. For
locked-answer measurements, have the operator physically lock the phone. Do not
use private UI selectors or change Focus settings automatically.

For the first enrollment launch, supply these process environment variables:

```text
SDK_DEVICE_QA_RUN_ID=<fresh UUID>
SDK_DEVICE_QA_SCENARIO=enrollment
```

The supported measurement scenarios are `locked-answer`, `active-call` and
`cold-reporting`. Configure the intended run while the app can launch, then use
the fixture's persisted readiness state before any cold push. A cold APNs launch
does not inherit the environment from a previous development-tool launch.
The fixture starts the SDK during application launch, before scene readiness.

Private app-container storage is under `Documents/SDKDeviceQA/`:

- `config.json`: persisted run/scenario configuration for subsequent cold launches;
- `token.txt`: the latest SDK PushService token; retrieve it after a fresh enrollment;
- `<run UUID>/<launch UUID>.jsonl`: launch-separated measurement traces.

Never print the token or add it to a trace, argument value, screenshot or public
artifact. The sender accepts a token **file path**. Use the matching sandbox
topic `<approved bundle identifier>.voip`; a token from another app or installation
is not interchangeable. Keep credentials and APNs payload files private with
directory/file modes `0700`/`0600`, and remove temporary key copies after use.

The existing [sandbox sender](../send-apns.mjs) sends once, reserves a private
receipt, and records an unknown outcome on transport failure. Reconcile that
outcome before retrying. HTTP 200 proves APNs acceptance; the current launch's
SDK ingress, report/completion and state traces must independently prove delivery
and behavior. Use the SDK's `incomingCall` envelope with `aps`, `eventId`,
`serverCallId` and `caller`; the historical raw probe's `from` payload does not
exercise SDK decoding. Fresh measurement attempts need fresh event identifiers;
deduplication tests deliberately reuse one.

## Evidence boundary

Keep raw build, provisioning, app-container and UI evidence private. Publish only
reviewed, sanitized receipts bound to the source identity and current launch.
Measure required-push reporting, active-call `mustReport`, genuine answer/action
delivery and audio activation separately. Process survival, APNs acceptance and
media flow are distinct observations. Missing or inconclusive evidence remains
pending; a build or an unlocked foreground run does not qualify a locked cold
launch.

Native timestamps are captured before serialization, but this instrumented
fixture writes JSON and synchronizes its trace file on MainActor. That work is
part of its measured action-to-audio path. Report the result as instrumented
fixture latency; it is not a production SDK latency baseline. Trace sequence
means append order, and background ingress retains its original timestamp when
its record subsequently reaches MainActor. Top-level application state and
conversation snapshots are sampled when appending; the nested native record's
timestamp and thread flag describe the original callback.
