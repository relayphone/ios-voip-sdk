---
status: proposed
---
# One calling framework per app build, LiveCommunicationKit by default

An app links exactly one calling-framework adapter, chosen at build time, behind the same SDK API. LiveCommunicationKit is the default; CallKit is an optional adapter. A process has a single provider slot, so the two can't be mixed per feature or per call. LiveCommunicationKit is Apple's stated direction and the route for China. CallKit stays available in case measurements show a gap LiveCommunicationKit can't close, such as allowed people breaking through Focus.

## Considered options
- LiveCommunicationKit only: no answer if Apple never closes a Focus gap.
- CallKit only: gives up China and Apple's newer system features.
- Switching per call: impossible with one provider slot, and re-presenting a filtered call would undo the user's Focus.
