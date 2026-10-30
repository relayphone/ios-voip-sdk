---
status: accepted
---
# Calls are identified by the app's Call ID across devices

Every call carries the app's Call ID, the same on every device that rings for it. The per-device UUIDs that CallKit and LiveCommunicationKit need are derived from it and never exposed. This makes answered elsewhere, declined elsewhere, VoIP push deduplication and server events all refer to the same call without lookup tables. Apps that have no server-side ID can't use these features.
