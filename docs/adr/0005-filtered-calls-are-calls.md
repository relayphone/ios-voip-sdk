---
status: accepted
---
# Filtered incoming calls are reported to the app as calls

When the system filters an incoming call because of Do Not Disturb, Focus or the block list, the SDK still creates the call and keeps the cause. By default the call becomes a call preview with reason filtered and the cause, and it never rings (see 0006). When the app's presentation policy doesn't preview filtered calls, the call ends with reason filtered and the cause. Ringing is never an option. Either way the app can send the call to voicemail or an assistant, or tell the caller. LiveCommunicationKit doesn't treat a filtered call as a call; it only returns an error to the report. The SDK never presents a filtered call again through the calling framework, because that would override the user's choice.
