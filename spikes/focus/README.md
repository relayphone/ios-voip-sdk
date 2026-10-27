# Focus device probe

Runner: `./run.sh F09 --dry-run`, `./run.sh C00 --listen`, and `./run.sh F01 --locked-auto-answer --listen`.
See [execution and the single microphone permission click](../../docs/research/focus/human-session.md).
Real runs require `FOCUS_DEVICE`, a signed `FOCUS_XCTESTRUN` and the documented APNs environment.
`./run.sh restore-all` recovers the persistent host journal. Runtime evidence goes to ignored `out/`
or private `FOCUS_WORK`; it must not be committed. Every command has a bounded timeout; unknown APNs
outcomes are never automatically retried. The approved system-setting changes need no new confirmation.
Additional row flags: `--provider callkit|lck`, `--calls Everyone` for C01, `--repeated-calls on|off`,
`--caller-format e164|national|generic`, and `--listen` for optional calibrated Mac RMS capture.
The aliases `CK-F13`, `CK-C02` and `LCK-C02b` select the requested comparison provider. `--caller-value`
can select an owned synthetic unknown number while the UI test contact keeps its E.164 value. Repeat pairs
wait at least 181 seconds after the last attempted VoIP push before their first call, then send the second
about 69 seconds later. An uncertain attempt is never automatically retried.
Scenarios with missing adapters or unsupported hardware/backend/fault controls return explicit automatic skips rather than human QA tasks.

Local CLI verification: `python3 -m unittest discover -s spikes/focus -p test_runner.py`.

## Morning batch

`spikes/focus/morning-batch --dry-run` executes every underlying row dry-run without a device or credentials.
For a real run, the operator supplies `FOCUS_DEVICE` for the iPhone 13, a private persistent `FOCUS_WORK`, and the
[sandbox APNs environment](../../discovery/device/README.md). The batch generates a signed test build with Xcode's
signed-in account and `-allowProvisioningUpdates`; it does not print the APNs key. It checks Share Across Devices is
off before any Focus change, then runs C06, C01 and C05 first, the calling controls and three-sample comparisons,
the Live Activity rows, and C00 `--listen` last. The Mac microphone prompt needs one Allow click. Existing
Live Activity rows that lack an adapter or require unsupported hardware are explicit skips; an APNs acceptance
or a partial update subcase is not full row qualification.

The batch atomically holds `~/.device-locks/<FOCUS_DEVICE>.lock` as a directory throughout mutation and restoration;
Phone's runner must honor the same convention for mutual exclusion. A pre-existing lock is never stolen. To yield
to Phone, create `FOCUS_WORK/PAUSE`, `~/.device-locks/PAUSE`, or `~/.device-locks/<FOCUS_DEVICE>.priority`;
the batch finishes the active row, restores settings and releases its lock. Remove the marker and rerun to resume
from the private checkpoint. An interrupted attempt is not repeated: after safe restoration it is recorded
unqualified. Failed restoration retains the lock and journal for recovery. The ringer switch is physical and its
position is not read by this harness, so an unattended session cannot claim either switch variant without independent evidence.

For individual rows, `--focus-mode dnd` snapshots/restores the built-in profile and refuses unknown or Silence list
modes; `--unknown-caller --caller-value <E.164>` verifies absence from Contacts; `--favorite yes|no` changes only the
owned contact. `--server-answer` writes a matched local test signal, never a cancellation-only VoIP push. The app
must be runnable to receive it; signal-to-UI-disappearance uses device uptime and is unqualified if the signal,
visible call or dismissal is missing. This is not a server-to-device network-latency measurement. The new DND,
Favorites and unknown-contact selectors are unqualified until tested on the operator's iPhone 13.

Matrix runs: `--keep-setup` keeps the owned Focus and contact between rows and only turns the Focus off after each
row; run `restore-all` once at the end. Selectors are qualified on iOS 27.0 (iPhone 13); see
[results](../../docs/research/focus/results.md). For selector work, the `dump:<controlcenter|focusmenu|settings-focus|settings-root|screen>`
UI action writes a read-only accessibility tree to the runner's Documents, and any failed action leaves the front
app's tree in `focus-dump-failure.txt`. The device operator has registered `group.dev.callkitsim.focus` for the
app, widget and filter under team `85A9MS6428`. Keep the App Group entitlements for C06; the earlier run built
without them and therefore did not qualify that row. For a signed device build, use Xcode's signed-in account and
`xcodebuild -allowProvisioningUpdates` with `DEVELOPMENT_TEAM=85A9MS6428`; do not pass ASC `-authenticationKey*`
arguments. The App Store Connect key cannot register groups.

Implements the native/platform portions of [the device plan](../../docs/research/focus/device-plan.md). This isolated spike chooses **one** provider at process launch: LiveCommunicationKit (default) or the CallKit `CXProvider` control. It never creates both in the same process, and has no SDK dependency, real media, backend AI or owner-join implementation. The two modes share one test bundle, so explicitly record the mode and all user settings. Build/dry-run qualification does **not** qualify device behavior. Claude operates the device; this lane does not.

```sh
spikes/focus/build.sh
```

Requires local Xcode 27.1 and XcodeGen. This runs `build-for-testing` for **generic iOS**, `CODE_SIGNING_ALLOWED=NO`, without installing or selecting any device. `FOCUS_BUILD_DIR` overrides its temporary DerivedData directory. Generated project/plists/entitlements come from `project.yml`; signing identities and profiles are not embedded. A later device build needs the operator's approved team, development APNs, Communication Notifications and the declared App Group on all three app/extension targets. Use a dedicated sandbox identifier, never the production Phone app. The unsigned product cannot be installed as-is.

## Configuration and exports

Write `Documents/focus.json` before launch. Unspecified fields are safe defaults:

```json
{
  "rowID": "F09",
  "provider": "lck",
  "handleType": "phoneNumber",
  "armed": true,
  "communicationNotification": false,
  "requestFocusAuthorization": false,
  "ringTimeout": 25,
  "activityAction": "start",
  "localUpdateInterval": 5,
  "localUpdateCount": 12
}
```

`activityAction` is `start` (foreground only), `end`, or absent. Local updates are bounded, silent and **foreground-runtime only**: suspension may stop the timer; use ActivityKit push-to-update to measure background cadence. Leave the interval absent for stale-date tests or server-only updates. A user can also invoke the **Start transcript** App Shortcut (`LiveActivityIntent`). Starts reuse an existing activity. There is no automatic push-to-start path requiring an alert.

The app registers PushKit at launch. Choose `provider` before launch (`lck` or `callkit`); changing it requires a process restart. Every genuine incoming push is reported, even when unarmed; `armed` controls the optional Communication Notification only. `mustReport` is recorded, not used to hide incoming reports in this probe. The LCK reporting task is scheduled from a private PushKit queue before delegate return; `reportTaskEntered` is a scheduling marker, not proof of private system-function entry. CallKit enters its synchronous completion-handler report from that queue. Focus sampling, donation and notification scheduling never gate report entry. Late report, completion, action/state and survival events use monotonic and wall timestamps. Missing survival events mean **unobserved/suspended**, not proof of termination.

CN-on donates a genuine incoming `INStartCallIntent` with `INPerson`, then posts updated **local** notification content at active interruption level. Authorize notifications once through the app; status/authorization has a separate trace. Do not treat its banner/sound as call ringing. Contact matching uses the caller's E.164 handle; People allowance behavior still needs measurement. The notification is deliberately alert-capable for the matrix; it is not part of silent transcript mode.

A dedicated ExtensionKit `AppIntentsExtension` owns `SetFocusFilterIntent` **AI call policy** and stores the selected value in the App Group. Native `focus.sample` and `push.received` events read it, without JS. Configure/remove this filter through Settings; the probe does not claim it knows which Focus owns the stored value. `focus.sample` records the **raw** status and authorization independently: the device pass observed raw `false` without authorization, so consumers must treat unauthorized/restricted/denied values as unknown. Authorization is explicit via the button or config, not triggered by an incoming call.

Exports are private app-container files:

| File | Meaning |
| --- | --- |
| `focus.jsonl` | Row/event, monotonic/wall timestamps, domain/code chains, outcomes 3–7, call states/actions, native policy and survival samples; no token or arbitrary error descriptions |
| `voip-token.txt` | Current PushKit token; never print, commit or upload as an artifact |
| `activity-update-token.json` | Current activity ID/surface ID/type and **per-activity** token; replaced on rotation, removed by End transcript; never print or commit |
| `activity-identity.json`, `activity-registration.json` | Non-secret persisted activity/surface identity and current registration generation; paired with the token before any ActivityKit push |

One activity is supported at a time. The persisted identity prevents a relaunch from silently creating a replacement; missing or ambiguous activity stops as unqualified until explicit `end`/reset. Rediscovery exports the existing `pushToken` and observes rotations. Before a push, the runner checks matching activity/surface IDs and token generation across relaunch and again immediately before sending. `--keep-setup` retains the activity for subsequent L rows; `restore-all` ends it. APNs HTTP 200 still does not prove rendering. Disable local timer updates while testing server push ordering.

## ActivityKit APNs payload

Use the per-activity exported token, `apns-push-type: liveactivity`, topic `dev.callkitsim.focus.push-type.liveactivity`, priority **5**, and the same sandbox credentials documented in [discovery/device](../../discovery/device/README.md). The VoIP sender intentionally accepts only `.voip`; do not send activity updates through it.

```json
{"aps":{"timestamp":1900000000,"event":"update","content-state":{"revision":1,"excerpt":"Synthetic caller: test update","updatedAt":1900000000},"stale-date":1900000030}}
```

Replace times with current increasing Unix seconds. Match Swift field names/types exactly, keep total JSON <=4096 bytes, and omit `alert`/sound. `stale-date` renders **Updates delayed** even if no app code is running. ActivityKit transport acceptance does not prove rendering; Claude/Hamza record Lock Screen observations. iPhone 13 has no Dynamic Island. Real captions/SIP take-over, unsupported security-policy triggers and Apple Intelligence remain separately qualified dependencies in the plan.
