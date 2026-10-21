# Sandbox APNs authentication and device delivery — October 21, 2026

Acceptance target: configure a sandbox team-scoped APNs key, retrieve it from
the Phone App vault, and send a real VoIP push to the dedicated iPhone probe
without exposing private material.

## Evidence produced

- Apple Developer showed the existing authentication key supported only Sign
  in with Apple. No APNs key existed. A new **Phone CallKit QA Sandbox** key was
  registered with **APNs only, Team Scoped (All topics), Sandbox**.
- The `.p8` is saved as **Phone APNs sandbox team key** in the Phone App vault,
  with scope/key/team metadata. Retrieval using the existing Phone service
  account matched the downloaded bytes. OpenSSL private-key validation and
  local P-256 ES256 sign/verify passed. Temporary APNs and provisioning key
  copies were removed after use.
- Ignored private operator configs were installed in the simulator clone,
  runtime worktree and library clone. The key has one private local file
  projection, referenced by those configs. Directory/file permissions were
  checked as `0700`/`0600`.
- The previous probe profile lacked `aps-environment`; registration produced no
  token. The new `discovery/device` target built successfully with Xcode 27.1
  (27A9275), automatic signing and `aps-environment=development`. It was installed
  under its existing probe ID on the dedicated iPhone 13.
- A fresh launch registered PushKit and received a 32-byte token. One send to
  `dev.callkitsim.probe.voip` returned **HTTP 200**, with response `apns-id`
  matching the request ID. See [receipt.json](receipt.json).
- The same launch then received the real push through the **metadata** delegate
  with **`mustReport=false`**, app state **foreground**, and no injected runtime.
  See [device-trace.jsonl](device-trace.jsonl).
- The subsequent incoming report returned
  `com.apple.CallKit.error.incomingcall:3`. Apple's SDK names code 3
  `CXErrorCodeIncomingCallErrorFilteredByDoNotDisturb`. Focus settings were not
  changed. This run does not qualify incoming UI, answer, or audio activation.

The raw container trace remains private because it appends earlier experiments.
The committed trace contains only selected events from this fresh launch; the
token bytes and payload values are excluded. The receipt intentionally retains
`deliveryConfirmed:false`: it represents APNs acceptance only. The separate
device trace supplies delivery evidence.

## Tooling and CI boundary

- `node --check` and Actionlint passed.
- A fresh reviewer ran seven synthetic checks with generated keys and mocked
  HTTP/2: successful/rejected/unknown outcomes, symlink invocation, receipt
  conflicts/missing parent/symlink rejection, mode `0600`, sandbox-only request
  headers and absence of synthetic credentials in output. No real APNs calls
  were made by the reviewer.
- The GitHub key projection is in **apns-sandbox-device-qa**, protected by a
  required operator reviewer and exact branch rules for `main` and
  `feat/runtime-engine`; these settings were queried after creation.
- The new GitHub workflow checks key retrieval and local ES256 signing only.
  [Hosted run 39574173320](https://github.com/ziahamza/callkit-simulator/actions/runs/39574173320)
  passed on macOS at `18513dee85cbad0dc75aec6770b61186bf855dfa`.
  Its output explicitly recorded `localES256Verified:true` and
  `apnsAuthenticated:false`; real authentication is established by the separate
  device send above.
- The device scenario completed at 128.900 s, with empty final calls and zero
  pending actions. No call was left active by this smoke test.

Still unmeasured here: a real push while a genuine call is active, cold launch
from a locked phone followed by answer, answer-to-audio latency, and native-to-JS
event replay after cold launch. No conclusion about those follows from this
credential smoke test.
