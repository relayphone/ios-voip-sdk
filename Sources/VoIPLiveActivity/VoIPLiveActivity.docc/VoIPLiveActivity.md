# ``VoIPLiveActivity``

Show call previews as Live Activities on the Lock Screen and in the Dynamic Island, and let the
user join them.

## Overview

A call that the system filters because of a Focus, that is answered elsewhere, or that the app's
presentation policy previews becomes a call preview: it never rings, opens no audio, and the user
can join it. This library shows each call preview as a Live Activity with a Join button, with
``CallPreviewActivities`` following the client's calls.

The system lets an app start a Live Activity only in the foreground, and most filtered calls
arrive in the background, so the app's servers usually start call previews with ActivityKit push
notifications. Their type is the SDK's ``CallPreviewAttributes``, whose JSON is a contract that the
SDK's repository describes in `docs/call-preview-activity.md`.

### Set up the app

1. Add `NSSupportsLiveActivities` to the app's Info.plist, and
   `NSSupportsLiveActivitiesFrequentUpdates` if its servers update previews often. Give the app
   the Push Notifications capability.
2. Create ``CallPreviewActivities`` as the app launches, and pass it to `VoIPClient.start` as an
   observer. The system launches the app in the background to deliver the push token of a preview
   that the servers started, so the observer must exist by then.
3. Send the app's servers the tokens from ``CallPreviewActivities/pushToStartTokens()`` and
   ``CallPreviewActivities/pushTokens()``, with ``CallPreviewActivities/authorization``.
4. Declare a ``JoinCallPreviewIntent`` in a file that both the app and its widget extension
   compile, with its `supportedModes` and `isDiscoverable`, and show the previews from the
   extension with ``CallPreviewView``.

The SDK never asks for permission: the system asks the user the first time one of the app's Live
Activities appears, and the user can turn them off in Settings. Read
``CallPreviewActivities/authorization`` to explain call previews first, or to show that they are
off.

### Test call previews

`FakeLiveActivityCenter`, in the `VoIPTesting` library, stands in for ActivityKit: pass it to
``CallPreviewActivities/init(options:center:)`` and act as the system and the app's servers. In
the iOS Simulator, the app starts real Live Activities in the foreground, and an iPhone simulator
with a Dynamic Island shows all of the view's presentations. Apple documents that the Simulator
receives ActivityKit push notifications on a Mac with Apple silicon or a T2 chip, which needs the
app's APNs credentials.

## Topics

### Showing call previews

- ``CallPreviewActivities``
- ``CallPreviewPushToken``
- ``CallPreviewDismissal``
- ``CallPreviewError``

### The Live Activity's type

- ``CallPreviewAttributes``
- ``CallPreviewStatus``

### Joining and views

- ``JoinCallPreviewIntent``
- ``CallPreviewView``

### The system's Live Activities

- ``LiveActivityCenter``
- ``ActivityKitAdapter``
- ``LiveActivityEvent``
- ``LiveActivityID``
- ``LiveActivityAuthorization``
