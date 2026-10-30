---
status: accepted
---
# How an incoming call appears is the app's policy, with defaults

For each incoming call, the app chooses the presentation policy: ring (the system call screen through the calling framework), preview (a call preview through Live Activities, which never rings and opens no audio), or nothing. The SDK ships defaults. A normal incoming call rings. A filtered call, or one answered elsewhere, is shown as a call preview. The app can change any of these per call or globally, for example letting its assistant answer first and only previewing the call. Joining from a preview starts a call on this device through the calling framework.

## Consequences
- The calling framework requires every VoIP push to be reported as a call. So a server that wants preview-only presentation sends a Live Activity push, not a VoIP push. The SDK provides both paths.
- An explicit answer or end by the user always wins over the app's policy (see 0003).
