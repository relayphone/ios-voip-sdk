# Expo configuration

The plugin writes native launch settings during Expo prebuild. Host controls verify generated settings and resource references; they do not qualify device signing, APNs delivery, or native resource playback.

```json
{
  "expo": {
    "plugins": [
      [
        "ios-voip-sdk",
        {
          "unhandledAction": "fail",
          "simulatorSupport": true,
          "includesCallsInRecents": true,
          "supportsVideo": true,
          "maximumConversationGroups": 2,
          "maximumConversationsPerConversationGroup": 2,
          "sounds": ["assets/ring.wav"],
          "defaultRingtoneIos": "ring.wav",
          "iconTemplateIos": "assets/call-glyph.png"
        }
      ]
    ]
  }
}
```

The plugin modifies Apple mods only. It adds `voip` to `UIBackgroundModes` once, preserving existing modes and other Info.plist keys. It adds `aps-environment: development` only when missing. An existing value is preserved; an explicit `apsEnvironment: "development" | "production"` selects the intended entitlement value. This is signing configuration, not an APNs credential or sandbox delivery assertion. Distribution provisioning must supply the matching entitlement.

The first six settings in the example are also their defaults. `unhandledAction` accepts `fail` or `accept`; the three flags require booleans; group limits require positive safe integers. The native reader receives this Info.plist dictionary:

```json
{
  "VoIPSDK": {
    "unhandledAction": "fail",
    "simulatorSupport": true,
    "includesCallsInRecents": true,
    "supportsVideo": true,
    "maximumConversationGroups": 2,
    "maximumConversationsPerConversationGroup": 2,
    "ringtoneName": "ring.wav",
    "iconTemplateImageName": "call-glyph.png"
  }
}
```

With no custom ringtone, `ringtoneName` is `default`; native maps that to the system ringtone. `iconTemplateImageName` is omitted with no icon. Unknown existing dictionary keys are preserved. Plugin options control the listed keys on each prebuild. Native must honor `simulatorSupport` before attempting runtime activation and must load the configuration during launch, before creating its one manager or registering PushKit.

Resource option names match the existing fork: `sounds`, `defaultRingtoneIos`, and `iconTemplateIos`. Paths are relative to the Expo app, must resolve to ordinary files inside that project, and must have unique filenames, including case. An icon must have a PNG extension and signature; image size/rendering is not measured by this plugin. A custom ringtone must name one of `sounds`. Standard Expo Xcode helpers register the resources in the application resource build phase. Generated copies live in the reserved `ios/<projectName>/VoIPSDKResources/` directory; each file keeps its basename in the app bundle. Repeated prebuilds atomically replace these owned copies without duplicating project entries or modifying unrelated hardlink referents. Conflicting existing Xcode filenames and escaping/symlink destinations fail instead of overwriting unrelated files. Group-relative references resolve to the copied file; unsupported custom group layouts and incomplete existing resource-phase bindings fail explicitly. Use a clean prebuild when removing or renaming previously generated resources; the plugin does not delete stale Xcode files on an incremental prebuild.

`microphonePermission` and `cameraPermission` accept a nonempty usage string or `false`. A string writes that usage description; `false` or omission preserves the existing value. The plugin does not add default media permission prompts. It adds the `audio` background mode when a media adapter is selected. Apps that already configure those values retain them.

The `defaultCallingApp` boolean defaults to `false` and controls the owned `com.apple.developer.calling-app` entitlement. The plugin preserves existing activity types and registers `INStartCallIntent`. See [default-calling delivery](../../Expo/M3-default-calling.md) for native ingress, listener buffering and remaining device checks. Legacy application timeouts/dialtone and Android-only options remain unsupported. LCK's actual action deadlines remain authoritative.

Run `node discovery/check_expo_plugin.cjs` for host controls that exercise generated settings, resource paths and Xcode project integration. These checks do not qualify device signing or push delivery.
