# Hosted M2 control-handshake red

**Measured red:** [39731064855](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39731064855), submitted `031dc16`, captured source `4d03b901`, passed native builds and failed with `deadline before fault handshake`. The [receipt](receipt.json) binds the unchanged artifact, source/build facts, first process trace/journal and cleanup. No final acceptance manifest was produced.

The first LiveKit process emitted 19 valid PROBE records, established local capture demand, then failed its 15-second fixture control wait before any incoming push or call journey. Its fixture result is false. The supervisor reports successful process completion; that is not application or media acceptance. The earlier malformed-frame failures remain separate evidence.

The original runner had two 30-second waits with the same error: console launch observation and matching runtime-session observation. It retained no phase arrival times. App and supervisor elapsed times have different origins, so the capture does not prove console latency or identify which wait expired. The original red is not reclassified as a successful journey.

The proposed runner now retires only a validated preceding session from the same owned run/bundle before launch, preserves those bytes, and waits directly for a fresh runtime session. Existing request/ACK/readiness and final launch/supervisor/journal PID checks remain unchanged. Phase timestamps are diagnostic observations, not replacement acceptance evidence. The fixture's 15-second wait and native action deadlines are unchanged; fresh hosted qualification remains required.

Shutdown exceeded its 30-second infrastructure budget; delete returned zero and inventory confirmed the owned simulator absent. Full product/log/journal bytes remain in the ignored capture. The lean receipt is an evidence index, not standalone replay input.
