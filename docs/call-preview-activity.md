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
ID, and whether the user allows Live Activities and frequent updates. Don't start a preview on a
device whose user turned Live Activities off.

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
the SDK does for the previews it ends. When the user joins the call on a device, the SDK there
removes that device's preview at once; update or end the previews on the user's other devices.

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
