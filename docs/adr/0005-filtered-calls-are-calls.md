---
status: accepted
---
# Filtered incoming calls are reported to the app as calls

When the system filters an incoming call because of Do Not Disturb, Focus or the block list, the SDK still creates the call. It ends it with reason filtered and gives the cause. The app can then send the call to voicemail or an assistant, tell the caller, or show it as a call preview, which never rings (see 0006). Neither Apple framework treats a filtered call as a call; each only returns an error to the report. The SDK never re-presents a filtered call, because that would override the user's choice.
