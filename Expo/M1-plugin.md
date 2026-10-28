# M1 Expo launch configuration

**Proposed:** this plugin writes the native launch settings for M1. The integrated native push journey remains the acceptance target. Host controls verify generated settings and resource references; they do not qualify device signing, APNs delivery, or native resource playback.

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

`microphonePermission` and `cameraPermission` accept a nonempty usage string or `false`. A string writes that usage description; `false` or omission preserves the existing value. This milestone does not add default media permission prompts or the `audio` background mode. Apps that already configure those values retain them.

Media adapter selection is M2. Default calling app entitlements, `tel:` links and call intents are M3. The plugin rejects unsupported options, including those features, legacy application timeouts/dialtone, and Android-only options. It adds no calling-app entitlement, Siri activity type, Android modification or audio adapter. LCK's actual action deadlines remain authoritative.

**Measured:** `node discovery/check_expo_plugin.cjs` passes 22 host control groups using the installed Expo 58.0.17 config-plugin implementation. It evaluates the real Expo mods and `node-xcode` resource helpers, checking idempotence, preservation, option validation, resolved source paths/bytes and application build-phase membership, collisions and path boundaries. The source-bound record is [checks.json](https://github.com/relayphone/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-m1-plugin/checks.json). Four initial implementation defects fail measured host controls in [review-red.json](https://github.com/relayphone/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-m1-plugin/review-red.json); their corrected controls pass. Source inspection of [Expo's SDK 55 Xcode helpers](https://github.com/expo/expo/blob/sdk-55/packages/%40expo/config-plugins/src/ios/utils/Xcodeproj.ts) confirms the resource/target helper APIs used here. Expo 55 native qualification is not claimed.

Independent spec and standards review each reported no remaining actionable findings after the resource-path, phase-membership and destination-preservation corrections. Reviewers performed no native execution.

Packaging integration must include `app.plugin.js` and `Expo/plugin` in the npm package and expose the plugin entry when package exports restrict subpaths. The parent M1 implementation owns those package metadata changes.
