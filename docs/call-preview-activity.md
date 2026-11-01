# Call preview Live Activity: the server contract

A call preview shows a call that is live elsewhere, such as one the system filtered because of a
Focus, as a Live Activity on the Lock Screen and in the Dynamic Island, from which the user can
join. The system lets an app start a Live Activity only while it is in the foreground, so the
app's servers usually start call previews with ActivityKit push notifications
([ADR 0010](adr/0010-call-preview-activity-is-sdk-type.md)). The SDK defines the Live Activity's
type, `CallPreviewAttributes`, and this document is the contract for the JSON that the servers
send. [`contracts/call-preview-activity.json`](contracts/call-preview-activity.json) holds the
payloads below and test vectors for every field; the SDK's tests decode them.

## Pushes

Send each payload to APNs as an ActivityKit push notification: the `apns-push-type` header is
`liveactivity`, and the `apns-topic` header is the app's bundle ID followed by
`.push-type.liveactivity`. Every date is a Unix timestamp in seconds.

| Push | Token | `event` | What it does |
| --- | --- | --- | --- |
| Start | The device's push-to-start token | `start` | Starts a call preview, and asks for its push token with `"input-push-token": 1`. |
| Update | The Live Activity's push token | `update` | Changes what the preview shows. |
| End | The Live Activity's push token | `end` | Shows the final state, then removes the preview at `dismissal-date`. |

The app sends its servers the push-to-start token, each Live Activity's push token with its call
ID, and whether the user allows Live Activities and frequent updates, all of which
`CallPreviewActivities` provides. Don't start a preview on a device whose user turned Live
Activities off.

When a call becomes a call preview while the app is in the foreground, the SDK starts its Live
Activity itself, and the app sends its servers that Live Activity's push token. In the background,
where the system refuses, the app can ask its servers to start one. The SDK keeps one preview per
call: when a second Live Activity starts for a call that already has one, it ends the newer one at
once.

The system asks the user about the app's Live Activities twice: on the first one that appears,
and again on the first one that a push starts, which asks whether to continue to allow them. The
system gives that push-started preview its push token only once the user answers the second
question, so until then the servers can't update or end it. On an iPhone 13 running iOS 27 the
token arrived 168 seconds after the start push, less than a second after the user tapped Always
Allow; later push-started previews got theirs at once. Give every start a `stale-date`, so that a
preview without updates shows that it is out of date, and end a preview as soon as its push token
arrives if its call is already over.

### Start

```json
{
  "aps": {
    "timestamp": 1800000000,
    "event": "start",
    "input-push-token": 1,
    "stale-date": 1800000120,
    "attributes-type": "CallPreviewAttributes",
    "attributes": {
      "callId": "call-1",
      "parties": [{ "handleType": "phone", "value": "+14155550123", "displayName": "Alice" }],
      "hasVideo": false,
      "metadata": { "room": "room-1" }
    },
    "content-state": {
      "status": "filtered",
      "startedAt": 1799999990,
      "statusText": "Your assistant is answering",
      "isJoinable": true
    },
    "alert": { "title": "Alice", "body": "Call in progress" }
  }
}
```

The system requires an `alert` to start a Live Activity. Leave out its `sound` so that the
preview never rings: a Focus silences it anyway, and a call preview must not act as a
substitute ringer. Start at most one preview per call and device.

### Update

```json
{
  "aps": {
    "timestamp": 1800000030,
    "event": "update",
    "stale-date": 1800000150,
    "content-state": {
      "status": "filtered",
      "startedAt": 1799999990,
      "statusText": "Your assistant is answering",
      "snippet": "They asked whether you can call back after six.",
      "isJoinable": true
    }
  }
}
```

Send the whole content state with each update. Use `apns-priority` 5 for snippets, which doesn't
count toward the system's budget for Live Activity pushes, and 10 only when the status or
`isJoinable` changes. An app that declares frequent updates gets a larger budget for priority 10,
unless the user turns them off, which the app reports. Move `stale-date` on with each update, two
minutes ahead: when no update arrives in time, the preview shows that its information is out of
date instead of a snippet that looks live.

### End

```json
{
  "aps": {
    "timestamp": 1800000090,
    "event": "end",
    "dismissal-date": 1800000210,
    "content-state": {
      "status": "ended",
      "startedAt": 1799999990,
      "statusText": "Call ended",
      "snippet": "They asked whether you can call back after six.",
      "isJoinable": false
    }
  }
}
```

End the preview on every device when the call ends, with a `dismissal-date` two minutes later, as
the SDK does for the previews it ends. Tell the app that the call ended over its own connection or
with a regular push, not a VoIP push: the device didn't present a call that it previews, and a
VoIP push about it costs a throwaway call report while the app isn't active, which can show
briefly on the call screen. The system terminates an app that doesn't report a VoIP push, and on
an iPhone 13, after three terminations in 21 minutes, it stopped delivering VoIP pushes to the app
until the app was reinstalled (see `VoIPPush`). When the user joins the call on a device, the SDK
there removes that device's preview at once; update or end the previews on the user's other
devices. The SDK also ends a preview that it follows when its call ends on the device, for
example after a server event.

## Attributes

The attributes describe the call and never change while the preview runs.

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `callId` | string | Yes | The call's ID, the same on every device; it must contain a non-whitespace character. Joining the preview joins this call. |
| `parties` | array | Yes | The parties on the other side of the call, possibly none. The preview shows the first. |
| `hasVideo` | Boolean | No | Whether the call includes video. Defaults to `false`. |
| `metadata` | object | No | Any JSON values, which joining the call passes on as the call's metadata. Defaults to `{}`. |

Each party is written like the caller of the SDK's default VoIP push:

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `handleType` | string | Yes | `phone`, `email` or `generic`. |
| `value` | string | Yes | The handle. A phone number may contain spaces, parentheses, hyphens and periods, which are removed; it must then be in E.164 format, such as `+14155550123`. An email address has one `@` with text on both sides. A generic value must contain a non-whitespace character. |
| `displayName` | string | No | The name to show. A blank name is ignored. |
| `additionalHandles` | array | No | The party's other handles, each with `handleType` and `value`. |

## Content state

The content state is what the preview shows now. Each update replaces all of it.

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `status` | string | Yes | `filtered` (the system filtered the call because of Do Not Disturb, a Focus or the block list), `answeredElsewhere`, `policy` (the app previews the call, for example while an assistant handles it) or `ended`. |
| `startedAt` | number | Yes | When the call started, as a Unix timestamp in seconds, which may have a fraction. The preview's timer counts from it. |
| `statusText` | string | No | The app's words for what is happening, shown instead of a description of `status`. |
| `snippet` | string | No | The latest line of the call's transcript or summary. Text longer than 240 characters is shortened to 240, ending with an ellipsis. |
| `isJoinable` | Boolean | Yes | Whether the preview offers Join. Send `false` with `ended`. |

## Rules

- The attributes and the content state together must not exceed 4 KB, so keep `metadata` small.
- Unknown keys are ignored, but an unknown `status` or `handleType`, or a missing required key,
  makes the whole payload invalid, and the system then doesn't start or update the preview. A new
  status will come with a new version of this contract.
- Dates are Unix timestamps rather than `Date`'s default `Codable` form, the seconds since 2001;
  the SDK's types read and write them so with the system's default JSON strategies.
- The `attributes-type` is the type's name without its module, so the contract holds whether the
  app installs the SDK with Swift Package Manager or CocoaPods. Renaming the type, or changing
  this JSON, breaks the servers that start call previews.
