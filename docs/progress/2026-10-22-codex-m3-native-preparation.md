# M3 native acceptance preparation

**Proposed; native acceptance pending.** This additive harness starts from M3 author commit `aae8fce5c85c9aeb36cd368a6e9cc503819f1b66`, before canonical M2 integration. No simulator was created, installed, launched or opened during preparation. The calling-app Settings UI, simulator eligibility and OS URL dispatch remain unmeasured.

The example's fixture now has an M3 mode. Its separate app-delegate subscriber observes actual OS URL or public start-call activity ingress without calling `VoIPSystemEntryPoints`, `DialRequestRouter` or an intent injection helper. The existing public `useConversationEvent('dialRequest')` callback passes its observed result to the fixture. Listener readiness follows the hook's subscription effect. Evidence contains destination/URL hashes, the video flag and conversation count, with run, process, simulator, sequence and wall-clock identity. Routing must leave the conversation list empty. This prepares a warm URL acceptance; it does not claim a cold-launch measurement.

`discovery/run_sdk_m3.py` accepts the committed, source-bound Release example and existing M0 build receipt. It verifies original executable and bundled JS bytes before creating a simulator, copies the app into a fresh private capture, ad-hoc signs that copy with the calling-app entitlement, and reads the actual signed entitlements back. The original app remains unchanged. The manifest binds the unsigned/signed executables, JavaScript, plist, signed entitlements and actual installed bytes. This is a runner-owned signing configuration, distinct from qualifying device provisioning or the plugin's generated signing settings. The plugin remains covered by its existing real Expo mod controls.

The runner creates exactly one simulator and uses the existing strict scenario supervisor. It waits for the actual public listener and matches its PID to the runtime session before requesting **`xcrun simctl openurl <owned UUID> tel:+15555550142`**. There is no forced target bundle, custom `tel` scheme, private default-app preference or direct helper substitute. The standalone gate requires the successful OS command, genuine native ingress and exact public event in order, the matching launcher/probe PID, source/build/install hashes, successful owned cleanup and an unchanged launchd environment. Missing delivery fails the gate. Read-only launchctl control processes disable child injection locally; app launches preserve unrelated inherited injectors. No global environment value is written.

## Run after integration and coordination

Commit the integrated source before rebuilding. Use the M0 workflow's source-before/build/receipt sequence so the example executable and `main.jsbundle` are bound to that exact commit, including the new example fixture and harness files. The runner adds these files to the existing M0 source inventory. Then, after the lead implementer releases the simulator slot:

```sh
python3 discovery/run_sdk_m3.py \
  --app "$SDK_M0_APP" --build-receipt "$SDK_M0_BUILD_RECEIPT" \
  --out "$PRIVATE_CAPTURE" --preboot-wait-seconds 180 --settings-wait-seconds 180
```

The optional preboot checkpoint writes `preboot-checkpoint.json` after creation and before boot. Announce that owned UUID, then copy its exact identity object to `boot-observation.json` within the configured deadline; a mismatch or timeout fails and enters owned cleanup. This allows a coordinated run to announce its UUID before booting it.

The capture directory must not exist. It is created with mode 0700 and holds the signed app copy, raw console output and evidence. Keep it ignored/private until reviewed for sharing.

The Settings checkpoint is deliberately manual pending the first public UI measurement. Apple's [default calling app guide](https://developer.apple.com/documentation/callkit/preparing-your-app-to-be-the-default-calling-app) describes OS `tel:` routing after a person selects the app. Once the listener is ready, the runner writes `settings-checkpoint.json` with the run ID, owned simulator ID and app PID. Select the example as the calling app through that simulator's genuine Settings UI. Only after observing that selection, write `selection-observation.json` with those same identity values, `"method": "public-settings-ui"` and `"selected": true`. This operator observation is recorded separately; it does not bypass OS dispatch or make a missing public event pass. A missing, mismatched or expired checkpoint fails and still deletes the owned simulator. TERM/INT also enter bounded owned cleanup, without touching unrelated processes or simulators.

For an already qualified unattended selection path, omit the Settings wait and invoke the same runner after the source-bound example build in CI, then require its exit status and `sdk_m3_conformance.py` summary. No unattended Settings selector has been measured or added yet. If this simulator does not expose the eligible app or cannot dispatch `tel:`, retain the red capture and keep M3 pending rather than substituting helper calls. Native Siri/Recents delivery, cold launches and device selection remain separate measurements.

## Measured preparation

The [preparation receipt](../verification/2026-10-22-m3-native-preparation/receipt.json) binds the changed sources and retained Expo interface/Clang inputs. Eleven synthetic host control groups execute the actual gate and runner at its external process boundary. They cover real-ingress/public-event requirements, process/dispatch/time binding, exact destinations, no created calls or private values, rehashed eligibility/build tampering, installed and supervisor evidence, signed-copy preservation, unchanged global environment, read errors/timeouts, OS dispatch failure, missing receipts and interruption cleanup. These controls use fake process results and do not qualify a simulator.

The current core/runtime/Expo module and changed Journey fixture compile against actual Expo 58 interfaces; package-source example TypeScript checks pass. The existing M0 controls, Python compilation and diff checks pass. Independent specification and standards reviews found no remaining actionable code findings; the standards review's missing TERM cleanup was corrected and covered by a mocked interruption. Actual linked example build, ad-hoc entitlement eligibility, Settings selection, `tel:` delivery and CI acceptance remain pending integration and the coordinated native run. No acceptance gate or production SDK routing API was changed.
