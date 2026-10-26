# Focus device probe

Runner: `./run.sh F09 --dry-run`, `./run.sh C00 --listen`, and `./run.sh F01 --locked-auto-answer --listen`.
See [execution and the single microphone permission click](../../docs/research/focus/human-session.md).
Real runs require `FOCUS_DEVICE`, a signed `FOCUS_XCTESTRUN` and the documented APNs environment.
`./run.sh restore-all` recovers the persistent host journal. Runtime evidence goes to ignored `out/`
or private `FOCUS_WORK`; it must not be committed. Every command has a bounded timeout; unknown APNs
outcomes are never automatically retried. The approved system-setting changes need no new confirmation.
Additional row flags: `--calls Everyone` for C01, `--listen` for optional calibrated Mac RMS capture.
Scenarios with missing adapters or unsupported hardware/backend/fault controls return explicit automatic skips rather than human QA tasks.

Local CLI verification: `python3 -m unittest discover -s spikes/focus -p test_runner.py`.

Matrix runs: `--keep-setup` keeps the owned Focus and contact between rows and only turns the Focus off after each
row; run `restore-all` once at the end. Selectors are qualified on iOS 27.0 (iPhone 13); see
[results](../../docs/research/focus/results.md). For selector work, the `dump:<controlcenter|focusmenu|settings-focus|settings-root|screen>`
UI action writes a read-only accessibility tree to the runner's Documents, and any failed action leaves the front
app's tree in `focus-dump-failure.txt`. Command-line automatic signing cannot add the App Group capability; without
it the Focus filter (C06) is unqualified.

Implements the native/platform portions of [the device plan](../../docs/research/focus/device-plan.md). This isolated spike uses LiveCommunicationKit only. It has no SDK dependency, `CXProvider`, real media, backend AI or owner-join implementation. Build and dry-run qualification do **not** qualify device behavior. Claude operates the device; this lane does not.

```sh
spikes/focus/build.sh
```

Requires local Xcode 27.1 and XcodeGen. This runs `build-for-testing` for **generic iOS**, `CODE_SIGNING_ALLOWED=NO`, without installing or selecting any device. `FOCUS_BUILD_DIR` overrides its temporary DerivedData directory. Generated project/plists/entitlements come from `project.yml`; signing identities and profiles are not embedded. A later device build needs the operator's approved team, development APNs, Communication Notifications and the declared App Group on all three app/extension targets. Use a dedicated sandbox identifier, never the production Phone app. The unsigned product cannot be installed as-is.

## Configuration and exports

Write `Documents/focus.json` before launch. Unspecified fields are safe defaults:

```json
{
  "rowID": "F09",
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

The app registers PushKit at launch. Every genuine incoming push is reported, even when unarmed; `armed` controls the optional Communication Notification only. `mustReport` is recorded, not used to hide incoming reports in this probe. The reporting task is scheduled from a private PushKit queue before delegate return; `reportTaskEntered` is a scheduling marker, not proof of private system-function entry. Focus sampling, donation and notification scheduling never gate report entry. Late report, completion, action/state and survival events use monotonic and wall timestamps. Missing survival events mean **unobserved/suspended**, not proof of termination.

CN-on donates a genuine incoming `INStartCallIntent` with `INPerson`, then posts updated **local** notification content at active interruption level. Authorize notifications once through the app; status/authorization has a separate trace. Do not treat its banner/sound as call ringing. Contact matching uses the caller's E.164 handle; People allowance behavior still needs measurement. The notification is deliberately alert-capable for the matrix; it is not part of silent transcript mode.

A dedicated ExtensionKit `AppIntentsExtension` owns `SetFocusFilterIntent` **AI call policy** and stores the selected value in the App Group. Native `focus.sample` and `push.received` events read it, without JS. Configure/remove this filter through Settings; the probe does not claim it knows which Focus owns the stored value. `focus.sample` records shared status/authorization on activation and button sampling; unknown stays null. Authorization is explicit via the button or config, not triggered by an incoming call.

Exports are private app-container files:

| File | Meaning |
| --- | --- |
| `focus.jsonl` | Row/event, monotonic/wall timestamps, domain/code chains, outcomes 3–7, call states/actions, native policy and survival samples; no token or arbitrary error descriptions |
| `voip-token.txt` | Current PushKit token; never print, commit or upload as an artifact |
| `activity-update-token.json` | Current activity ID/surface ID/type and **per-activity** token; replaced on rotation, removed by End transcript; never print or commit |

One activity is supported at a time. After dismissal or process loss, a token file alone does not prove an activity is still alive. Rediscover on foreground and confirm activity state; fetch the latest registration before sending. Disable local timer updates while testing server push ordering.

## ActivityKit APNs payload

Use the per-activity exported token, `apns-push-type: liveactivity`, topic `dev.callkitsim.focus.push-type.liveactivity`, priority **5**, and the same sandbox credentials documented in [discovery/device](../../discovery/device/README.md). The VoIP sender intentionally accepts only `.voip`; do not send activity updates through it.

```json
{"aps":{"timestamp":1900000000,"event":"update","content-state":{"revision":1,"excerpt":"Synthetic caller: test update","updatedAt":1900000000},"stale-date":1900000030}}
```

Replace times with current increasing Unix seconds. Match Swift field names/types exactly, keep total JSON <=4096 bytes, and omit `alert`/sound. `stale-date` renders **Updates delayed** even if no app code is running. ActivityKit transport acceptance does not prove rendering; Claude/Hamza record Lock Screen observations. iPhone 13 has no Dynamic Island. Real captions/SIP take-over, unsupported security-policy triggers and Apple Intelligence remain separately qualified dependencies in the plan.
