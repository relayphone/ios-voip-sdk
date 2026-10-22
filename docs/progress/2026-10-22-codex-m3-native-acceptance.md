# M3 native acceptance: default calling

**M3 remains pending.** The SDK and Expo `dialRequest` implementation is
prepared; the acceptance target is an actual OS-dispatched `tel:` link reaching
the example's public hook. Host tests and successful Settings selection alone
do not complete it.

**Measured exploratory result, iOS 27.0 / Xcode 27.1, source `a24ac916`:** normal
Xcode simulator entitlement packaging produced a launchable example which
appeared in Default Apps → Calling. A headless public XCTest test observed it
already selected, tapped its row and observed it still selected. Direct
`simctl openurl` returned `LSApplicationWorkspaceErrorDomain` 115. A separate
real Safari `tel:` anchor tap displayed “Safari cannot open the page because
the address is invalid.” Neither path produced native ingress or a public
`dialRequest`. The [exploratory receipt and selected UI evidence](../verification/2026-10-22-sdk-m3/exploratory-ios27/receipt.json)
record the artifacts and all three owned simulators' independent absence.

These are diagnostic measurements, not a fully qualified native journey.
Some exploratory UI revisions lack a complete retained source/binary cohort;
the direct dispatch also inherited a stale fixture run ID from boot. No
universal simulator limitation, stable meaning for error 115, or missing SDK
declaration is established. Physical-device delivery remains unmeasured.

**Measured signing defect in the original harness:** placing the restricted
calling-app entitlement in a post-build ad-hoc host signature caused AMFI error
−424 (“The file is adhoc signed but contains restricted entitlements”). The
replacement builder lets Xcode emit the simulator claim in the executable's
`__TEXT,__entitlements` section. The runner verifies that section from the
exact installed executable and rejects a calling/dialing claim in its host
signature. It copies the built app unchanged. This follows Apple's
[simulator entitlement guidance](https://developer.apple.com/forums/thread/791736);
it does not qualify device provisioning.

The tracked public Settings test uses only controls observed in the actual UI.
It records before/after screenshots and accessibility trees, taps the example
and requires selected state. Missing controls, an ineligible candidate, a
different device or stale run/PID fail before dispatch. The test's executable
and original run configuration are build-bound; the runner changes only the
run identity and appends any inherited injector to XCTest's existing injector.
The simulator's global environment is never written. Fixture variables are
passed only at app launch, after boot.

The strict runner then executes `simctl openurl` on its own UUID without a
forced bundle, custom URL scheme or private preference. It requires genuine
native ingress and the exact public hook event in order, with matching process
identity and zero conversations. Failure stays failure. Cleanup is bounded on
success, error, TERM and INT; it deletes only the runner's simulator. The
existing supervisor and conformance gates are retained.

## Source-bound local result

**Measured, source `d216355ba76b1f52d8c292bc418f3be8e932b0cf`:** the corrected
normal-Xcode Release build and public Settings test both passed. Build-time
and installed executable, JavaScript and plist hashes match; all nineteen UI
product files and the configured run file are bound. App PID `49371` matches
the console launcher, runtime session and Settings selection result. The
actual public row tap passed with before/after selected state and screenshots.

The exact `simctl openurl` then returned 115. No native ingress or public
`dialRequest` arrived. The standalone gate exited 1 with `M3 control failed:
os-tel-dispatch`; the run remains red. After that failure the owner stopped the
example, so its incomplete supervisor receipt is retained without claiming a
terminal success. The [source-bound red receipt](../verification/2026-10-22-sdk-m3/native-red-d216355/receipt.json)
(SHA-256 `04171327046e1960b1ba86ec497b5ea86cf7877ddee3d4c9689de8b6d50f12a0`)
contains the actual selection, dispatch, source/build hashes and cleanup.
The one owned simulator was shut down and deleted, then independently absent
from inventory; launchd's original environment remained unchanged. Full
binaries, raw paths and console remain private and hash-bound. The public
PROBE excerpt is for reading and is never substituted into a gate trace.

Independent specification and standards reviews cleared the harness before
this frozen-source run. The standards review corrected uncertain-create
cleanup, build-time plist binding and bool/float protocol aliases; focused
controls cover each. The hosted comparison is still pending.

## Shared console transport integration

**Proposed correction; fresh hosted qualification required.** M3 integrates
M2 parent `031dc16c5b798d5c849ae745a8798605954ee40f`, including M1's reviewed
plain-console candidate. Only the M3 example launch changes from
`simctl launch --console-pty` to public `--console`; its existing runner host
control checks that external command. The SDK, supervisor, Settings helper,
strict gates and local `d216355` OS 115 evidence are unchanged. The parent's
[synthetic native experiment](../verification/2026-10-22-sdk-m1/native-console-transport/receipt.json)
scopes the transport observation; it is not an M3 delivery measurement.

Before this source update, [hosted run 39729097105](../verification/2026-10-22-sdk-m3/hosted-before-plain-console/receipt.json)
was still queued at head `6227dc2`, attempt 1, with no job steps or native
artifact. Any deliberate cancellation or supersession supplies no acceptance;
the PR description records the later result. The new exact head must qualify
through the unchanged real-OS delivery gate.

## Hosted Settings correction

**Measured at submitted head `fc1d42e`, captured test-merge source `941819d`:**
hosted public-tel run `39731348570` attempt 1 timed out during simulator boot,
before app installation. Its original archive remains separate. The authorized
unchanged-head attempt 2 booted iOS 26.5, installed the build-bound example and
observed the actual public listener at PID `20498`. Settings launched, but its
root accessibility tree contains one unnamed collection view. The helper's
iOS 27 identifier lookup failed before scrolling or selecting a calling app.
XCTest exited 65; no OS `tel:` command ran. The later attachment-validator error
does not establish an eligibility or routing failure. The strict replay stays
red because dispatch evidence is missing.

The [attempt 2 receipt and actual Settings screen/tree](../verification/2026-10-22-sdk-m3/hosted-settings-red-fc1d42e/receipt.json)
bind the original artifact digest, clean captured source, installed bytes,
48 UI products, 17 same-device attachments, three build logs and the matching
launch/listener PID. Shutdown and delete returned zero; inventory confirms
absence and the sampled launch environment is unchanged. The supervisor did
not complete a successful journey. This hosted run does not compare OS routing
with the local iOS 27 result.

**Proposed correction:** retain the named collection view when present;
otherwise require exactly one observed collection view in Settings. Zero or
multiple candidates still fail with UI evidence. A host control compiles the
actual Swift query policy with the XCUI boundary replaced and checks named
precedence, one unnamed list, no list and ambiguous lists. All selection,
identity, screenshot/accessibility, real OS dispatch and public-event gates
remain unchanged. Fresh exact-source native qualification is required.
The [corrected host checks](../verification/2026-10-22-sdk-m3/hosted-settings-red-fc1d42e/corrected-host-controls.json)
record nineteen passing groups and successful typechecking of the actual
Settings test against the installed simulator XCTest interfaces.

## Build and measure

Commit the integrated sources first. Select the default media variant, install
the example's own dependencies, run Expo prebuild, then run `pod install` from
`example/ios`. The shared `ProbeTraceWriter.swift` must be discovered by CocoaPods.
Apple's [default calling requirements](https://developer.apple.com/documentation/callkit/preparing-your-app-to-be-the-default-calling-app)
are generated by the existing plugin; no custom `tel` registration is added.

```sh
export SDK_EXAMPLE_MEDIA_ADAPTER=none
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm exec --workspace ios-voip-sdk-example -- expo prebuild --platform ios --no-install
(cd example/ios && pod install)
bash discovery/build_sdk_m3.sh "$PRIVATE_BUILD"
python3 discovery/run_sdk_m3.py \
  --app "$PRIVATE_BUILD/Example.app" \
  --build-receipt "$PRIVATE_BUILD/build-receipt.json" \
  --settings-products "$PRIVATE_BUILD/settings-products" \
  --out "$PRIVATE_CAPTURE" --preboot-wait-seconds 180
python3 discovery/sdk_m3_conformance.py "$PRIVATE_CAPTURE"
```

Build and capture paths must be fresh. The optional preboot checkpoint writes
the exact owned UUID/run ID before boot: announce that UUID, then copy
`preboot-checkpoint.json` to `boot-observation.json` within the deadline. Omit
the checkpoint for unattended CI. No simulator starts during the builder.
Raw captures remain private until reviewed for sharing.

**Measured host preparation:** [eighteen M3 control groups and final workflow checks](../verification/2026-10-22-sdk-m3/host-controls-d216355.json) pass, including
rehashed binary/Settings tampering, stale identity, environment read errors,
OS dispatch failure and interruption cleanup. The tracked public UI test
compiles with Xcode 27.1; `actionlint` and shell syntax checks pass. These
controls mock external processes and do not qualify delivery. The new workflow
will run the same strict path on hosted macOS 26 / Xcode 26.6, recording its
actual simulator OS. Hosted iOS 26.5 behavior is a proposed comparison until
its receipt exists. No red-to-green exception is present.
