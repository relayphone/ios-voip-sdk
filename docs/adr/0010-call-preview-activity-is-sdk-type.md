---
status: proposed
---
# A call preview's Live Activity is the SDK's type, and the app's servers start it

The SDK defines the attributes of a call preview's Live Activity, `CallPreviewAttributes`, and documents their JSON as a contract, so that the app's servers can start a call preview with a push-to-start token, and update or end it with the Live Activity's push token. The system lets an app start a Live Activity only in the foreground, and most filtered calls arrive in the background, so a call that becomes a call preview there gets its Live Activity from the servers. The SDK starts one itself only in the foreground, and ends it when this device joins the call or the call ends. The SDK ships the attributes, their token streams, joining from the Live Activity, and default views; the app owns the widget extension that shows them.

## Considered options
- Attributes that each app defines: every server builds its own payloads, and the SDK can't route Join.
- A VoIP push for call previews: the system requires each one to be reported as a call, so the call would ring (see 0006).

## Consequences
- A push-to-start names the attributes' type, so renaming `CallPreviewAttributes` or changing its JSON breaks the servers that start call previews.
