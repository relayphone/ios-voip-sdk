# Conformance host, version 0

Validate the shared catalog and run the host checks with the existing tools:

```sh
node tools/conformance/runner.ts
node tools/conformance/v1.ts
npm ci --prefix tools --ignore-scripts --no-audit --no-fund
npm run typecheck --prefix tools
node --test tools/conformance/*.test.ts
```

`model.ts` hand-defines portable wire records. `schema.ts` validates the deliberately bounded
JSON Schema subset and performs semantic value checks; adding a schema keyword requires explicit
support and tests. `fixtures.types.ts` supplies literal positive/negative type witnesses, which
tests compare with every JSON fixture. `wireID` validates strings before constructing branded wire
identifiers; JSON decoding performs the same check without trimming or normalization. No language
types are generated.

`JourneyDriver` is the integration seam. Implement it with the actual native core/system fake,
iOS simulator runtime or Android emulator runtime. `apply` injects a control and drains ready
native work without waiting for a virtual deadline that a later `advance` supplies. `observe`
returns fresh, complete evidence; each implementation bounds its own native I/O/waits. Advance
uses virtual time on hosts and bounded native deadline observation in integration drivers.

An incoming control with `deferAdmission: true` waits for `admitted`. A Hold with
`deferConfirmation: true` waits for `holdApplied`, which completes the recorded request.
`latePermit` completes the original timed-out claim with an allow. The fake authority's `unknown`
reconciliation completes at its deadline so the pending interval can be observed.
Process and authority controls configure the ports, and `advance` drives timer inputs. The
transition table names the resulting reducer inputs, such as `claimExpired` and `authorityAllowed`.

Expectations are explicit projections: lifecycle kind/reason, line/alias/gates, per-call counters,
participating IDs, typed errors and normalized system end class. Unknown timestamps/action IDs
are not guessed; native receipts retain them. Refusal expectations can require the typed reason
independently of the call's canonical end/preview reason. A missing zero counter fails instead of inventing
zero. Counts need complete observation coverage, and drivers must reject overflow/gaps. `missed`
and `remote` describe semantic system end classes, retaining actual platform codes separately.
`endResult` checks the latest completed End result for the call. `ringingPublications` counts
native ringing snapshots even without JavaScript. `claimTimeouts`, `permitReleases` and
`holdRequests` count timeout observations, permit releases and issued Hold requests respectively.

The runner sends no expected results to drivers. It observes only at `expect` steps, closes on
reset/input/assertion failure, and preserves cleanup errors alongside the original failure.
The catalog command validates data only: it never reports a journey or platform as qualified.
`selectTransition` exercises table selection from explicit guard facts; it computes no domain state.
No platform driver or replacement domain engine ships in this initial skeleton. The tests use
scripted observations solely to prove host assertions and cleanup, not native conformance.

Version 1 lives under `spec/v1`. The version-aware model reader dispatches to an explicit
schema by envelope version and resolves v0 schema references from the bundled local file.
The v1 catalog also validates platform condition coverage in `spec/capabilities.json`. Both
journey versions share the driver lifecycle and can assert v0 observations.

V1 controls configure native descriptors and fake ports. `refuseNotificationPost` configures
the candidate surface to refuse its next post. The fallback remains independently observable.
`enablePrejoin` supplies a deterministic attempt ID for the fake. `mediaFeedback` delivers
provider or system observations for that attempt. The prejoin fake starts with audio inactive,
confirms transport on `prejoined` and waits for explicit promotion and activation feedback.
`toneTransport` sets whether a Tones transport is installed, independently of general media.

The retention journey sets small age/count limits in `budgets.retention`. A deferred system
removal remains outstanding after logical end. The later `systemRemoved` callback completes
that operation. A `cleanup` assertion requires an independent completion that the engine matched
to its owner. The driver then exposes the post-pruning call roster, including retained terminal
records. `callAbsent` requires a complete roster.

`record` checks one current observation for a record's identity. Notifications are keyed by
call and surface with separate slots for latest refusal and visibility. Media and routes are
keyed by call, push registration and health by installation and
channel, capabilities by feature and optional call, and timing events by clock and sequence.
Supply the latest registration or presentation evidence for its key. Duplicate entries for
the asserted key fail. An `actionError` describes the latest requested action's actual typed
failure for that call. Drivers must observe its completion before asserting it.
