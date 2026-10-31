---
status: proposed
---
# The SDK configures the audio session, and only the system activates it

The SDK configures the audio session for each call, through the `AudioSession` seam, just before it prepares the call's media, so the configuration is in place when the answer, start or join completes and the system activates audio. It never activates or deactivates the session: for LiveCommunicationKit calls only the system does, and the calling framework reports it. Interruptions and media services resets reach the state machine as events, so it stays the owner of call state (see 0001). After a reset the SDK configures the session again. Once an interruption ends, or after a reset, a call that takes part and isn't on hold ends with reason failed unless the system activates audio within the recovery deadline, 5 seconds by default. A call whose session can't be configured also ends with reason failed, because it would take part with no microphone. Everything that imports AVFAudio lives in the `VoIPAudio` library, so `VoIPCore` stays testable on macOS.

## Considered options
- The app configures the session, as before: every app has to get the order right, and interruptions never reach call state.
- Configure once at launch: a media services reset loses the configuration, and calls with video need other options.
- Start the recovery clock when the interruption begins: it ends calls during long interruptions, such as Siri, that the system recovers from. Starting it when the interruption ends leaves a call silent until the user ends it if no end is reported.
- Activate the session when the system recommends resuming: the recommendation is advice, and activating competes with the calling framework.
- Fold the session into `CallMedia`: every media implementation would repeat the configuration and interruption handling.
