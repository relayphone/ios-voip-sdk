# M3 native acceptance preparation

**Historical preparation; M3 acceptance remains pending.** This harness began at
`aae8fce5c85c9aeb36cd368a6e9cc503819f1b66`, before M2 integration. The
[preparation receipt](../verification/2026-10-22-m3-native-preparation/receipt.json)
records host controls and compilation against actual Expo interfaces. It did
not qualify a simulator or a default calling app.

The example's separate app-delegate subscriber observes actual OS URL or public
start-call activity ingress. The public `useConversationEvent('dialRequest')`
hook supplies the result. The gate requires run, simulator, PID, sequence and
wall-clock identity, the exact destination hash, and no created conversation.
This prepares a warm URL measurement; cold launch and native Siri/Recents
delivery remain separate measurements.

The original proposed runner signed an app copy after building. Exploration
subsequently measured an AMFI restricted-entitlement rejection. That path and
the manual Settings checkpoint have been replaced by normal Xcode simulator
entitlement packaging and a small public XCTest Settings test. See the
[current native handoff](2026-10-22-codex-m3-native-acceptance.md) for the measured
red, its limits, and current build/run instructions. The historical receipt
does not attest the replacement path.
