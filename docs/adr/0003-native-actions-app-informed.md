---
status: accepted
---
# The SDK performs call actions itself and informs the app

The SDK fulfils answer, end, hold, mute and play-tones actions itself, then tells the app. It does not wait for the app (or its JavaScript) to approve them. Only starting an outgoing call waits for the app, which has to place it. When the app is cold-launched from the lock screen, its JavaScript may not be running yet; making the system wait for it either fails the answer or leaves the user hearing nothing. If media can't be connected afterwards, the call ends with reason failed.
