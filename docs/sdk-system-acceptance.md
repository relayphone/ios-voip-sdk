# System-origin SDK acceptance (A5)

**Proposed native acceptance.** `SDK_SYSTEM_ACCEPTANCE=1` extends the existing
M0 runner with seven separately gated cases on its one owned simulator:

| Case | External control and expected public SDK path |
| --- | --- |
| `answer-end` | Push → system answer → join handler → backend connected report → system end |
| `decline` | Push → system decline → end handler, without joining |
| `hold-accept` | Connected first call + waiting second → device D5 Hold & Accept composition |
| `end-accept` | Connected first call + waiting second → device D5 End & Accept composition |
| `mute-echo` | System mute, duplicate optional-report push, pending app mute with same-value system echo, automatic echo, system tones, system end |
| `provider-reset` | Explicit selected-provider reset fault → SDK `providerReset` event and empty state |
| `push-launch` | External staged push starts a stopped process → actual PushKit callback → system answer pending without a handler → handler attachment → backend connected report → system end |

**Proposed recipe.** Build the usual source-bound M0/M1 products and a control
package from the same committed checkout, then run:

```sh
CKSIM_BUILD_ARCHS="$(uname -m)" bash scripts/build-runtime.sh "$SDK_SYSTEM_CONTROL_PACKAGE"
SDK_M1_ACCEPTANCE=1 SDK_SYSTEM_ACCEPTANCE=1 bash discovery/run_sdk_m0.sh
```

The existing M0 product/build variables remain required. The control package
supplies the shipping `cksim` CLI and notifier; its runtime libraries are never
injected into the SDK app. The runner preserves the inherited child loader
value, uses the SDK's built-in runtime, and retains the exact external command
requests/responses. It creates no additional simulator. Cleanup is independently
checked through the device inventory and the owned device directory.

The repeated valid PushKit invitation still enters the actual incoming-report
wrapper on the original native UUID. Its expected duplicate error is normalized
for the known live call; it must not create another conversation, ring or handler
request. Optional-report metadata does not suppress that valid invitation attempt.

**Proposed control transport.** `cksim push --launch --run-id <run>
--launch-receipt <fresh-file>` writes one fixed-path envelope under the app's
Documents directory and becomes `simctl launch --console`. It refuses a running
app service. The runtime claims the envelope once, checks uid, modes, type,
bundle/run/nonce and its 30-second lifetime, and queues delivery through the
actual registered PushKit delegate. The example does not inject that push.
An interrupted launch leaves evidence to inspect; neither the CLI nor runner
retries an unknown outcome. This simulator transport is not an APNs, locked
launch, background scheduling or device PushKit qualification.

**Proposed evidence contract.** The separate system gate first validates its
parent M0 manifest. It binds the original supervisor traces, PID acknowledgements,
runtime journals, product/source identity, CLI package, command receipts and
cleanup. Native CX action IDs are bound through the CLI; public LCK conversation
and pending IDs remain separate. D5 compositions come from the committed ui10
device trace. A journal clock bracket checks settlement against actual platform
deadlines; handlers/pending state expose the earlier A2 policy deadline. Backend
connected reports occur only after native join fulfillment and an actual
connecting projection. Existing M1 cases retain their app-origin restriction.
The manager marker identifies the sole `VoIPApplication.start` owner. SDK event
hooks retain real conversation scope for watchdog events; session and provider
callbacks remain process-wide and carry no fabricated conversation identifier.

**Boundary.** The `reset` operation is an explicit fault on the selected provider.
It does not model R3 invalidation of older providers or change provider routing.
It refuses while that provider has any pending runtime action. The mute-echo case
checks this refusal; the separate provider-reset case resets a connected call
with no pending action. A reset never discards an action awaiting settlement.
The delayed app-mute barrier checks A3's pending-value filter; it does not measure
the device's delayed-fulfill echo timing.

**Measured host controls.** `discovery/check_cli_controls.py`,
`discovery/check_cli_push_launch.py`, `Tests/PushLaunch/run.sh` and
`discovery/check_sdk_system.py` exercise serialization, secure consumption and
strict synthetic evidence rejection. Their green results are host evidence only;
the native cases above remain pending an integrated A0/A2/A3/A8 build and capture.
