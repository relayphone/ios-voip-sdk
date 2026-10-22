# iOS Expo module

The iOS-only Expo module exposes the conversation API specified by
[RFC 0001](https://github.com/ziahamza/expo-callkit-telecom/blob/rfc/v2-conversations-api/rfcs/0001-v2-conversations-api.md).
See [the M1 API](M1-API.md), [launch configuration](M1-plugin.md), and
[M2 audio integration](M2-AUDIO.md) for usage and the limits of current evidence.

## Shared native sources

`IosVoipSDK.podspec` lives at repository root so it can compile `Sources/` and
`Expo/apple/` directly, without copying Swift sources. `ExpoModulesCore` is always
required; only the selected LiveKit adapter adds its typed RN/WebRTC dependency.
LiveCommunicationKit and the simulator runtime belong to the shared SDK sources.
The separate `CKLoader.m` external injection loader is excluded.
The pod sets `CKSIM_SDK_SOURCE=1` and derives `CKSIM_RUNTIME_VERSION` from the
repository's canonical `VERSION` file.

The module configuration lists `apple` only, and the podspec restricts the platform
to iOS 17.4 or later. The example uses Expo SDK 58, React 19.3 and React Native 0.88.
One npm workspace installation supplies both the module and example.

Expo 58 provides the UIKit scene lifecycle required when building for iOS 27.
Prebuild generates the scene delegate and manifest; Expo keeps the React Native
factory in its app delegate and forwards scene events to app delegate subscribers.
The SDK does not take ownership of the example's launch or window lifecycle.
Expo's documented minimums are iOS 16.4 and Xcode 26.4, so the SDK's iOS 17.4
deployment target and the Xcode 26.6/27.1 build environments remain supported.
Actual native acceptance on each environment is recorded separately.

## Native integration seam

The wrapper expects the following symbol from the shared Swift sources:

```swift
public enum SimulatorSupport {
  @MainActor public static func activateIfNeeded() -> Bool
}
```

Activation must be idempotent. It returns whether the simulator runtime is active;
on devices it returns `false`. Failure logs its reason and allows genuine system
behavior, as required by `docs/START-HERE.md`. The wrapper dispatches to `MainActor`
before calling it. The launch owner subsequently creates the SDK's single manager.

`IosVoipSDK.bootstrap()` is exposed only through the package's explicitly internal
`ios-voip-sdk/internal/bootstrap` entry. It returns `{ platform: 'ios', simulator,
runtimeActive }` for the example's status screen. It is M0 infrastructure with no
public API stability promise. Ring/join acceptance remains separate from bootstrap.

The CocoaPods resource bundle is named `IosVoipSDKRuntime`. It currently includes
the profile under `profiles/` and also recognizes the planned canonical location
`Sources/Engine/Resources/`. Native integration must resolve the profile from this
bundle. SwiftPM uses its own `Bundle.module` accessor.

## Validation

From repository root:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm run typecheck
npm run format:check
npm exec --workspace ios-voip-sdk-example -- expo config --type prebuild
npm exec --workspace ios-voip-sdk-example -- expo-modules-autolinking resolve --platform apple
pod ipc spec IosVoipSDK.podspec
```

These checks validate TypeScript, configuration and discovery of the pod. They do
not compile Swift, test simulator activation or prove call behavior. Native
acceptance is recorded separately in milestone evidence; these commands alone do
not establish it.

The scaffold uses direct TypeScript compilation instead of the larger
`expo-module-scripts` development toolchain. Dependency versions are pinned in
`package-lock.json`. The package remains private and unlicensed before beta.
The example declares its own pinned `babel-preset-expo` dependency so Babel can
resolve it directly even when npm nests Expo's transitive copy.

## Primary references

- [Expo SDK 58 compatibility map](https://github.com/expo/expo/blob/sdk-58/packages/expo/bundledNativeModules.json)
- [Expo SDK 58 platform and toolchain minimums](https://docs.expo.dev/versions/v58.0.0/)
- [Expo scene lifecycle migration](https://github.com/expo/fyi/blob/main/ios-scene-lifecycle.md)
- [Expo module configuration](https://docs.expo.dev/modules/module-config/)
- [Expo root-relative podspec resolution](https://github.com/expo/expo/blob/sdk-58/packages/expo-modules-autolinking/src/platforms/apple/apple.ts)
- [CocoaPods file patterns](https://guides.cocoapods.org/syntax/podspec.html#file_patterns)
- [Expo iOS deployment target configuration](https://docs.expo.dev/versions/v58.0.0/sdk/build-properties/)
