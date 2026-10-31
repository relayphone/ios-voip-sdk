---
status: accepted
---
# LiveCommunicationKit is the SDK's only calling framework

The SDK presents calls with LiveCommunicationKit alone. It has no CallKit adapter, and an app doesn't choose a calling framework; the `CallingFramework` seam stays for the test fake and the simulator. This replaces a proposal to make LiveCommunicationKit the default and keep CallKit as an optional adapter per app build, in case LiveCommunicationKit couldn't let a Focus's allowed people through. Measurements on an iPhone 13 running iOS 27.1 settled it:

- Speed: LiveCommunicationKit shows an incoming call about a second sooner. From a cold launch, Accept and Decline were on screen 0.05–1.7 s after the VoIP push, against 1.2–2.0 s with CallKit, and the report returned in about 0.1 s, against about 1.1 s.
- Apple's direction: WWDC26 session 226 asks CallKit apps to move to LiveCommunicationKit, and newer system features arrive in LiveCommunicationKit.
- China: CallKit can't be active in apps on the China mainland storefront. LiveCommunicationKit has no such restriction.
- Focus without CallKit: when a Focus doesn't allow the app, LiveCommunicationKit filters the call, and the SDK reports it to the app as a filtered call (see 0005). The app can then post a call communication notification, which the Focus lets through only for the people it allows (3 of 3 tries); show a call preview as a silent Live Activity (see 0006); and learn when the Focus turns on or off from a Focus filter (`SetFocusFilterIntent`), which ran within about 0.8 s without launching the app (7 of 7 tries).

## Considered options
- LiveCommunicationKit by default, with CallKit as an optional adapter: a second adapter to test and document, for a Focus gap the notification covers.
- CallKit only: slower to show a call, against Apple's direction, and not available on the China mainland storefront.
- Choosing the framework per call: a process has one provider slot, and presenting a filtered call again would undo the user's Focus.

## Consequences
- A Focus's allowed people and its Repeated Calls setting don't make a LiveCommunicationKit call ring; the call is filtered.
- Apple documents CarPlay calling only for CallKit. It is unverified with LiveCommunicationKit.
- CallKit's Call Directory extension doesn't apply.
