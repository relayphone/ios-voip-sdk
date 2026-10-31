---
status: accepted
---
# The SDK owns call state

The SDK keeps its own state for every call, keyed by Call ID. The calling framework, LiveCommunicationKit (see 0002), is only the surface that presents it. CallKit keeps no list of calls, and LiveCommunicationKit's conversation objects change identity over a call's life. Mirroring either one forced about 15 reconciliation tables into the old client, and made the SDK's behaviour depend on framework quirks.
