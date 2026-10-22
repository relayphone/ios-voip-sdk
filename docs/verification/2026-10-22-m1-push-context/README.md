# Simulator async push context controls

`red-correlation.json` is a measured identifier-only projection of the immutable
pre-fix M1 capture. It binds journals and supervisor receipts by SHA-256 without
copying push payloads or tokens.

`host.json` binds the production source bytes used by the focused host control.
Run `python3 Tests/VoIPSDK/run_push_context.py` to repeat it. The helper extracts
and compiles the exact production task-local and association value types, then
exercises their asynchronous and cleanup behavior. Compiler checks are separate
from native acceptance, as their receipt states.

These controls do not establish simulator end-to-end acceptance or device
PushKit behavior. The unchanged strict native gate remains required after the
client report-site integration.

`report-scope-host.json` is the later source snapshot for report-scope cleanup.
The original `host.json` remains the snapshot for `c037cae`; its compiler checks
were performed before this followup. The later focused control verifies that
unused context is removed before a serialized report operation resolves, even
when its platform call would fail before entering the runtime hook. This is an
invariant control, not a newly measured native failure.
