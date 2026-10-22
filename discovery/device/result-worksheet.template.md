# Private SDK device result worksheet

Copy into an ignored mode-0700 run directory; keep this populated copy mode 0600.
Do not commit it or publish raw traces, screenshots, token files or device/app
identities. Empty fields are unknown, not passing observations.

- Status: **not run** (later: measured / inconclusive / failed)
- Scenario / run UUID:
- Actual device OS / toolchain:
- Original build source commit / source-input SHA256 / executable SHA256:
- Build receipt SHA256 / native input-byte comparison:
- Private command receipts, logs, exit statuses and SHA256:
- Enrollment/readiness launch UUID and PID / intended persisted config verified:
- Token enrollment evidence (presence only here; token stays in its separate file):
- Incoming payload SHA256 / fresh eventId / serverCallId:
- Sandbox sender receipt SHA256 / APNs status / requested and returned APNs IDs:
- Delivery confirmed by actual SDK ingress (not inferred from APNs status):
- Measured launch UUID / PID / trace SHA256 / sequence completeness:
- Delivery UUID / report conversation UUID / action UUID(s):

## D1 — locked cold answer

- Known readiness PID terminated / scoped absence evidence and time:
- Physical lock observation / observer / time / any intervening app launch:
- Cold launch and actual push ingress evidence:
- System incoming UI and human answer gesture evidence / timing uncertainty:
- Join `action.ingress` native nanoseconds / action and conversation UUID:
- Genuine `audio.activated` native nanoseconds in the same launch/process:
- Join-ingress-to-activation milliseconds (no negative/different-clock delta):
- Human-tap-to-activation result, only if separately measured:
- Conclusion / limits / missing evidence:

The callback delta includes synchronous instrumented trace work. It is neither
the human gesture delay nor a production SDK latency baseline. No activation
leaves the latency unanswered.

## D2 — mustReport during an active conversation

- Reference conversation UUID / joined and connected evidence before push:
- State around delivery / reference ended or 60-second cleanup reached:
- Actual `push.ingress` API / metadata `mustReport` / native timestamp:
- Delivery UUID / report result / completion mark:
- Conclusion / limits / missing evidence:

A legacy callback or a push after the active conversation ended cannot answer
the active metadata-value question. Record observed values without predicting them.

## D3 — cold reporting check

- Known readiness PID terminated / scoped absence evidence before push:
- Any intervening app launch / cold launch proof:
- Actual ingress API / required `mustReport` evidence:
- Matching delivery UUID across ingress, report attempt/result and completion:
- Report succeeded / error category and code if present:
- Observation window chosen before send (proposed 30 seconds; no Apple-deadline claim):
- Same PID and launch identity observed at window start/end / actual elapsed time:
- Process exit/restart or unavailable observation evidence:
- Conclusion / limits / missing evidence:

Completion marks invocation, not a system reporting-check acknowledgement.
Success supports observed survival after required reporting in this run; an
optional push, APNs 200 alone, successful report alone or a new process does not.

## Closure

- End-all / terminal conversation evidence / copied traces and command files hashed:
- Credentials removed / temporary key copies removed (no key material here):
- Public sanitized receipt proposal (review before publication):
- Unanswered D1/D2/D3 fields / next specific action:

Media transport, audio-engine health and R3 are outside these measurements.
