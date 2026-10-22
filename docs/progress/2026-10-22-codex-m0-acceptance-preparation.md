# M0 acceptance preparation

**Proposed:** the M0 acceptance is a Release Expo example that reports an incoming LCK conversation, remains ringing for one second, joins, and ends with the source runtime activated before manager creation. Native acceptance has not been measured by this preparation. The complete M0 handoff must add the local run and CI evidence before claiming the milestone accepted.

The workflow `.github/workflows/sdk-m0.yml` builds the locked Expo 55 workspace, bundles JavaScript into its Release app, compiles the Swift package for simulator and device, and builds the source bootstrap and device link probes. CI selects macOS 26 and Xcode 26.6. Its evidence records the actual simulator OS and build selected by the runner; this does not imply iOS 27.0 simulator coverage. The embedded behavior profile remains the device-measured `ios-27.0` profile.

## Reproduce with prebuilt products

Commit all source inputs before building. Capture a source snapshot **before** the build commands:

```sh
python3 discovery/sdk_m0_conformance.py --begin-build "$BUILD_ROOT/source-build-start.json"
```

Build the Release Expo app with a nonempty `main.jsbundle`. Build the source bootstrap with `bash discovery/build_sdk_bootstrap.sh "$BUILD_ROOT/bootstrap"` and the device link probe with `bash discovery/build_sdk_device_probe.sh "$BUILD_ROOT/device"`. Compile the `VoIPSDK` Swift package for both generic iOS Simulator and generic iOS destinations, keeping the device DerivedData. The workflow contains the exact build commands and captures their nonempty logs.

Set these paths to the products of those builds:

- `SDK_M0_APP`: Release Expo `.app`.
- `SDK_M0_BOOTSTRAP_APP`: source `SDKBootstrap.app`.
- `SDK_M0_DEVICE_PROBE`: `SDKDeviceProbe` executable, with its adjacent `SDKDeviceProbe.build-info.json`.
- `SDK_M0_SPM_DEVICE_DIR`: SwiftPM device DerivedData containing the three target object sets.
- `SDK_M0_BUILD_RECEIPT`: a fresh receipt path.
- `SDK_M0_BUILD_LOGS`: a directory of nonempty build logs.

Bind the exact product bytes after the builds, then measure:

```sh
python3 discovery/sdk_m0_conformance.py --record-build "$SDK_M0_BUILD_RECEIPT" \
  --build-start "$BUILD_ROOT/source-build-start.json" --app "$SDK_M0_APP" \
  --bootstrap "$SDK_M0_BOOTSTRAP_APP" --device-probe "$SDK_M0_DEVICE_PROBE" \
  --spm-device-dir "$SDK_M0_SPM_DEVICE_DIR"
OUT="$BUILD_ROOT/evidence" bash discovery/run_sdk_m0.sh
```

The output directory must not exist. Source changes between the snapshot, builds, and acceptance cause failure. The runner verifies the build receipt before creating a simulator and again after the run. It retains executable, bundled JavaScript, device object, symbol, trace, supervisor receipt, installed image, environment, source, build log, and cleanup hashes in the evidence manifest. Run IDs, bundle IDs, process IDs, conversation UUIDs, and callback sequence bind the Expo journey to the measured app. Missing, empty, stale, or mismatched evidence fails validation.

The runner creates and boots one owned simulator, runs the Expo journey and the healthy, bad-profile, and post-install PushKit-hook refusal bootstrap cases serially, then deletes that simulator. All potentially blocking simulator operations have deadlines. It never requests runtime injection or changes the simulator launchd environment. An existing external `DYLD_INSERT_LIBRARIES` value is preserved per launch; evidence records its presence and digest without its paths. An inherited SDK runtime or loader injection is refused.

The linked device probe compiles all shared sources into one device executable and checks that actual runtime implementation symbols are absent. It is never installed or executed on a device. Separately, the checker examines the SwiftPM device objects from every shared target. Swift module and resource accessor bookkeeping, including `__swift_FORCE_LOAD`, is allowed; the check does not claim that every device object has zero bytes.

## Preparation evidence

**Measured:** `python3 discovery/check_sdk_m0.py` passes five offline control groups covering a complete bound fixture and negative controls for the journey, bootstrap refusal, stale source or products, receipts, symbols, cleanup, and missing or empty logs. These controls mock native inspection and do not establish simulator behavior. `bash -n` passes for the runner and probe builders; the workflow passes `actionlint`. Independent specification and repository standards reviews reported no remaining actionable findings after adding the build-time source receipt.

**Open:** perform the native local run and this workflow on the final integrated source, retain their evidence, and record the accepted M0 result for Claude's review. No device behavior or newer simulator OS coverage is inferred from these preparation checks.

**Measured harness correction:** a completed Xcode 27.1 SwiftPM device build uses target directories named `CKSimRuntimeC-t.build`, `CKSimRuntime-t.build`, and `VoIPSDK-t.build`. Object discovery now accepts those and the older exact `<target>.build` spelling only immediately below `Release-iphoneos`. This avoids treating the outer project `VoIPSDK.build` as the target. A sixth offline control group reproduces the five observed device object paths, rejects counterfeit target names, simulator objects and combined products, and requires every target to remain present. This path correction requires a new source snapshot and native build receipt before acceptance.
