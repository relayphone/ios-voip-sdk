# iOS-only Expo module

The package root exports the public conversation API: state and push-token hooks,
handlers, commands, reports, audio routes, typed incoming callers and
`receiveCallEnded` for backend ownership signals. Read the [API contract](../docs/expo/api.md)
and [answered-elsewhere guide](ANSWERED-ELSEWHERE.md) for application behavior.

The API design follows [RFC 0001](https://github.com/relayphone/expo-callkit-telecom/blob/rfc/v2-conversations-api/rfcs/0001-v2-conversations-api.md).

The Expo 58 example, native conversation/PushKit journeys, selected LiveKit Release
build and device-code exclusions pass [SDK CI](https://github.com/relayphone/ios-voip-sdk/actions/runs/40693437174).
The [LiveKit runtime journeys](../docs/expo/livekit.md) exercise healthy hold/resume/end and
stale-audio watchdog cleanup on the existing React Native audio engine. Native [default-calling requests](M3-default-calling.md) deliver `tel:` URLs and resolved start-call intents to the public `dialRequest` hook, with native buffering until a listener attaches. Device Settings/Siri dispatch remains to be measured. The [review checkpoint](../docs/progress/2026-10-28-m-stable.md)
records the remaining acceptance and device-measurement limits.

## Shared native sources and startup

`IosVoipSDK.podspec` compiles `Sources/`, `Expo/apple/` and the selected media binding
directly, without copying Swift sources. `ExpoModulesCore` is always required;
selected media bindings add their own native dependencies. The external
`CKLoader.m` injection loader is excluded. The pod sets `CKSIM_SDK_SOURCE=1` and
derives `CKSIM_RUNTIME_VERSION` from the repository's `VERSION` file.

`VoIPAppDelegateSubscriber` starts the shared `VoIPApplication` and PushKit service
during native app initialization, before JavaScript or a UI scene is required.
The module reuses that process owner and its single `ConversationManager`.
Handlers and hooks attach to the existing native client.

The shared SDK calls `SimulatorSupport.activateIfNeeded()` before creating its
manager. Activation is idempotent, returns `false` on devices, and preserves genuine
framework behavior if simulator activation is refused. SwiftPM and CocoaPods SDK
simulator builds embed the canonical runtime profile; the runtime implementation
and profile are guarded out of device builds. No runtime resource bundle is
required by the module.

`IosVoipSDK.bootstrap()` remains an explicitly internal diagnostic entry at
`ios-voip-sdk/internal/bootstrap`. It returns `{ platform: 'ios', simulator,
runtimeActive }` for the example's status display. It does not replace the public
conversation API or establish call acceptance by itself.

## Requirements and example

The module supports iOS 26 or later and builds with the iOS 27 SDK or newer;
CI uses Xcode 27.1. Its configuration lists `apple` only. The example pins Expo 58,
React 19.3 and React Native 0.88; the declared Expo peer range is 55–58. Runtime
compatibility with Expo 55–57 remains unqualified.

One npm workspace installation supplies the module and example. Expo owns its
scene, window and React Native lifecycle; the SDK registers native services through
an app-delegate subscriber. See the [example guide](../example/README.md) for
prebuild and Release builds.

## Validation

From repository root:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm run typecheck
npm run format:check
node --test Expo/tests/m1-runtime.test.cjs
npm exec --workspace ios-voip-sdk-example -- expo config --type prebuild
npm exec --workspace ios-voip-sdk-example -- expo-modules-autolinking resolve --platform apple
pod ipc spec IosVoipSDK.podspec
```

These commands validate JavaScript, types, configuration and pod discovery. Native
compilation, simulator journeys and device Release exclusions are separate CI
checks linked above. Dependency versions are pinned in `package-lock.json`; the
package remains private and unlicensed before beta.

## Primary references

- [Expo SDK 58 compatibility map](https://github.com/expo/expo/blob/sdk-58/packages/expo/bundledNativeModules.json)
- [Expo SDK 58 platform and toolchain minimums](https://docs.expo.dev/versions/v58.0.0/)
- [Expo scene lifecycle migration](https://github.com/expo/fyi/blob/main/ios-scene-lifecycle.md)
- [Expo module configuration](https://docs.expo.dev/modules/module-config/)
- [Expo root-relative podspec resolution](https://github.com/expo/expo/blob/sdk-58/packages/expo-modules-autolinking/src/platforms/apple/apple.ts)
- [CocoaPods file patterns](https://guides.cocoapods.org/syntax/podspec.html#file_patterns)
- [Expo iOS deployment target configuration](https://docs.expo.dev/versions/v58.0.0/sdk/build-properties/)
