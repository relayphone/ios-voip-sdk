# System dial requests

**Proposed native integration:** `tel:` URLs and resolved public
`INStartCallIntent` activities become the RFC's `dialRequest` event. The app
decides whether to start a conversation. The example displays the requested
destination and audio/video capability without placing a call.

```tsx
useConversationEvent('dialRequest', ({ handle, video }) => {
  // Present the destination; call startConversation when the user confirms.
});
```

Enable eligibility for user-selected default calling on iOS/iPadOS 18.2 and
later with the plugin:

```json
{
  "expo": {
    "plugins": [["ios-voip-sdk", { "defaultCallingApp": true }]]
  }
}
```

The plugin writes `com.apple.developer.calling-app: true` only when enabled.
Disabling it removes that owned entitlement. It always registers
`INStartCallIntent` in `NSUserActivityTypes`, preserving other activity types.
It preserves the existing `voip` background mode and unrelated entitlements.
Provisioning must permit the entitlement, and the user selects the calling app
in Settings. The minimum SDK deployment target remains iOS 17.4. EU default
dialing is deferred.

Expo 58 forwards cold scene URLs and user activities to the SDK's public
app-delegate subscriber after starting React Native. Requests are retained in
the native process until an actual public `dialRequest` listener attaches;
creating the module or its internal transport subscription does not drain
them. Removing the final listener detaches delivery. During JS reload, a newer
native module lifetime retires the old consumer, and stale teardown cannot
detach the new one. Pending requests last for the process lifetime; delivered
events are not a persistent inbox.

The Swift package exposes `DialRequestRouter.shared.observe` for native
consumers and `VoIPSystemEntryPoints` for application/scene forwarding. Expo 55
uses its public application callbacks. Custom scene hosts, including a custom
Expo 55 scene integration, forward cold connection options and warm callbacks
on main:

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
  VoIPSystemEntryPoints.handle(connectionOptions: connectionOptions)
}

func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
  for context in contexts { VoIPSystemEntryPoints.handle(url: context.url) }
}

func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
  VoIPSystemEntryPoints.handle(userActivity: userActivity)
}
```

Standard Expo 58 scene forwarding already does this; custom hosts should
choose one forwarding path. The public helper also accepts `INStartCallIntent`
directly. A resolved intent must identify one recipient through its contacts
or call-back record. Unresolved or multi-recipient requests remain unhandled.
Siri resolution in an app extension remains the host's responsibility.

**Measured host scope:** genuine public Intents objects, URI parsing, buffering,
listener readiness, ownership and Expo config mods pass focused controls.
Native URL delivery, default calling selection, signing, and Siri/Recents
delivery are not qualified by those controls. The [research note](../docs/research/2026-10-22-system-dial-entry-points.md)
binds the public Apple and Expo lifecycle APIs used here. The source-bound
[host receipt](../docs/verification/2026-10-22-sdk-m3-host/checks.json) includes
current-source typechecking against actual Expo 58 framework interfaces.
