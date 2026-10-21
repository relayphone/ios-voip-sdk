# R8: simulator OS coverage evidence

**Measured historical CI environment:** [hosted run 39680771297](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39680771297), artifact `callkit-discovery-macos-26-xcode-26.6`, source commit `6fbd880e4ed0815e91659de63facb9d620b9ef05`. `ci-environment.txt` and `ci-runtimes.txt` are unchanged copies of that public artifact's environment and runtime inventory. They show selection of `com.apple.CoreSimulator.SimRuntime.iOS-26-5`, version **26.5**, build **23F77**, with active/selected Xcode **26.6 (17F113)** on macOS **26.6.2 (25G83)**. The `ios-27.0` profile names the device behavior under comparison. Neither the compiler matrix nor that profile name proves iOS 27.0 simulator or LCK coverage.

**Measured offline checks:** `environment-controls.txt` records nine unit tests at the shipping `build_identity` seam. They cover 20 missing/invalid manifest-field subcases, source-file absence/emptiness, changed OS/compiler builds, profile/OS confusion, invalid runtime inventory and selection, separate OS/profile/compiler summary fields, and historical replay labelling. Fixtures are explicitly synthetic; they are not native execution evidence. `image-identity-controls.json` and `harness-controls.json` record the existing image and harness controls after the change.

**Measured red:** on base `7aa2d5a`, `test_shipping_identity_rejects_missing_simulator_os_build` failed with `AssertionError: ValueError not raised`; the old shipping identity gate accepted a manifest lacking the simulator OS build. The historical-summary test then failed with `KeyError: 'qualification'` before replay labelling was added.

**Proposed pending fresh native/CI execution:** new captures save `simctl list runtimes -j` as `runtimes.json` and the selected compiler's `xcodebuild -version` as `compiler-version.txt`. The manifest binds the selected runtime ID, OS version/build and compiler version/build to those files. Strict shipping checks reject missing or inconsistent fields. The summary exposes `environment.behaviorProfileID`, `environment.simulatorOS` and `environment.compiler`; historical fixtures remain `qualification: historical-replay`.

No simulator was created for this change. Fresh integrated CI remains required to measure collection of the new metadata; a historical capture is not backfilled into a new qualification.

Repeat the offline checks from the repository root:

```sh
python3 discovery/check_environment.py
python3 discovery/check_image_identity.py
python3 discovery/check_harness.py
bash -n discovery/run.sh
```
