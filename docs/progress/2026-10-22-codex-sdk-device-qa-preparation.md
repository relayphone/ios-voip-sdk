# SDK device QA preparation — 2026-10-22

This is preparation for START-HERE §4.D after the M1 simulator acceptance. No
device behavior is qualified by this change. The fixture builds the canonical
SDK sources, owns no additional manager, provider or PushKit registry, and starts
`VoIPApplication` from the application delegate before scene readiness.

## What changed

- `SDK_DEVICE_QA` gates every added SDK diagnostic type, callback and symbol. The
  ordinary Swift package and Expo products do not enable it.
- Native PushKit ingress records the actual API and `mustReport`, generates a
  delivery UUID, and captures a common monotonic-clock timestamp. The receiver
  captures that UUID synchronously before creating a task; TaskLocal context
  follows the actual serialized LCK report, including a predecessor wait.
- Hooks record the actual report attempt/result, action ingress/settlement and
  LCK audio activation/deactivation. The completion mark is immediately before
  invoking the existing exactly-once PushKit completion, not an observation of
  the system's reporting check.
- The native fixture persists run configuration and launch-separated typed JSONL
  records in protected private files. A token is written only to its separate
  private file; neither tokens nor raw payloads enter traces. Trace sequence is
  append order; an event retains its original native timestamp if it first
  needs to hop to MainActor.
- The build-only script takes the approved signing identity from the environment,
  uses a generic device destination, binds the app to committed source bytes,
  and verifies both profile and signed-app APNs entitlements. Generated signing
  artifacts remain private. It never installs or launches the app.

## Measured compiler and host evidence

The source-bound receipt is
[`2026-10-22-sdk-device-qa-host.json`](../verification/2026-10-22-sdk-device-qa-host.json).
The toolchain is Xcode 27.1 (27A9275), Swift 6.4, with the installed iPhoneOS 27.1
SDK targeting iOS 17.4. These are compiler/host measurements only:

- Actual shared Swift SDK, storage and native entry typecheck with Swift 6
  warnings as errors, including the Debug diagnostic configuration. The normal
  SDK configuration also typechecks with the flag off.
- Actual Objective-C diagnostic and PushKit-owner sources pass device-target
  syntax checks with the flag on and off.
- Diagnostic host controls cover thread delivery, scoped context restoration,
  per-push identity across actual queued reports, exactly-once completion,
  privacy, monotonic timestamps and positive/negative diagnostic-symbol checks.
- Storage host controls cover persisted configuration, launch isolation,
  JSONL validation, token invalidation, private modes and refusal of unsafe
  symlinks, hardlinks, FIFOs and replaced paths. Host tests do not exercise iOS
  data-protection behavior while physically locked.
- Existing core, push-policy and terminal-projection/report-serialization host
  controls pass. Builder controls mock native tools; they prove script checks,
  not signing or an actual native build.

Independent spec and standards reviews found no actionable issues against M1
base `387558275bdd1ff43185a567be646999f69afa69`. The standards reviewer separately
verified all 31 receipt input hashes and all 12 successful command results.

## Proposed device phase and remaining evidence

Follow [`discovery/device/SDK-README.md`](../../discovery/device/SDK-README.md)
using only the approved dedicated QA phone. No credential fetch, APNs request,
device installation or launch occurred while authoring this preparation.

1. Enroll while awake and unlocked, retrieve the separate private token file,
   and persist a fresh run/scenario before a cold launch. Environment from a
   prior development launch is not assumed to survive APNs launch.
2. For locked answer, the operator physically locks the phone and answers its
   system UI. Measure actual native action ingress to actual `didActivate` on
   the common clock. Operator gesture time is separate; it is not inferred
   from handler ingress. Synchronous MainActor JSON/`fsync` trace work is part
   of the instrumented path; this is not a production SDK latency baseline.
3. For active-call `mustReport`, establish a joined reference conversation and
   send a fresh valid invitation. Read the actual API/metadata event; application
   state alone is not evidence of `mustReport`.
4. For the cold reporting check, require a bound cold launch, actual required
   push ingress, LCK report result, completion invocation and bounded process
   survival. APNs HTTP acceptance or successful LCK report alone is insufficient.

Actual iOS protected-file access, development signing, locked cold launch,
PushKit reporting enforcement and audio activation timing remain pending.
The fixture configures an audio category and fulfills actions; it does not
establish media transport or prove audio engine health. R3 remains unchanged.
