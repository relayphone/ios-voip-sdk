# A7 ownership and A4/A8 integration preparation

**Measured:** [host-checks.json](host-checks.json) records exact SDK/test input
hashes and host/compiler results for the local correction stack. It preserves
preparation failures, including the typed duplicate-linkage control that failed
before the union/guard fix. Earlier M2 native captures retain their original
sources and conclusions.

The ownership controls compile two optimized Swift SDK dylibs containing the
actual application, selection, `finishLaunch`, event emission and Objective-C
process claim. They verify both SDK load orders, concurrent claims, duplicate
static symbols, conflicting adapter/configuration/policy, omitted repeat adapter,
reentrant startup, one initial false authorization, and a typed process ownership
event without a conversation ID. LCK/PushKit/media/provider interception are
explicit host facades; these controls do not measure Apple framework behavior.

The whole-client controls retain the actual client, handler, activation
coordinator, adapter ordering and serial executor, with explicit platform/audio
edges. They pass seven mute and ten conversation-contract groups. Separate audio
controls cover preparation, cancellation, watchdog behavior, lifecycle paths,
queueing and optional LiveKit source behavior. The compiler checks use installed
iOS/watchOS SDKs and include default and opt-in device Release plus the native
contract fixture. No native app was linked or launched.

Principal reproduction commands:

```sh
python3 discovery/check_sdk_ownership.py
python3 discovery/check_platform_shims.py
python3 Tests/AudioSessionQueue/check_audio_compilation.py
bash Tests/VoIPSDK/run_mute_echo.sh
bash Tests/VoIPSDK/run.sh
python3 discovery/check_expo_bridge.py
python3 discovery/check_device_release.py
npm run build
npm run typecheck
node --test Expo/tests/m1-runtime.test.cjs
```

TypeScript checks require the locked dependencies. This run temporarily linked
an existing exact-lock dependency directory and removed its own link afterward;
no installation or dependency edits were performed.

**Pending:** integrated simulator journeys, current pod-built Release `iphoneos`
inspection, hosted CI and physical device measurements. A0.1's blocked-main
report-entry correction remains separate and unfinished. No simulator, physical
device, APNs, PushKit registration or native call acceptance is claimed here.
