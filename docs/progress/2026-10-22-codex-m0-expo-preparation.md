# M0 Expo preparation — October 22, 2026

This is a preparation handoff for M0, not a completed milestone. Native runtime
integration, Swift compilation and the plain-simulator incoming ring/join journey
remain pending. No simulator or device was used for these checks.

## Expo 58 dependency update

**Proposed:** use Expo's maintained scene lifecycle implementation for the example
instead of adding a custom scene bridge to the original Expo 55 scaffold. The
[official migration guide](https://github.com/expo/fyi/blob/main/ios-scene-lifecycle.md)
states that apps built with the iOS 27 SDK must adopt scenes and that Expo 58
generates the required scene delegate and manifest while preserving app delegate
subscribers and the React Native factory. The [versioned support table](https://docs.expo.dev/versions/v58.0.0/)
lists iOS 16.4+ and Xcode 26.4+, preserving this SDK's iOS 17.4 minimum and supporting
the Xcode 26.6/27.1 build environments. Exact native artifact compatibility and the
complete ring/join acceptance remain native verification work.

The updated workspace pins Expo 58.0.17, React 19.3.0, React Native 0.88.0,
`expo-build-properties` 58.0.11, `babel-preset-expo` 58.0.19,
`react-native-safe-area-context` 5.10.1 and `@types/react` 19.3.0. The Expo npm
package's compatibility map supplies the React, React Native and safe-area versions;
the lockfile records the resolved transitive packages. Peer ranges cover the Expo
58 / React Native 0.88 / React 19.3 line being qualified. The existing Expo Modules
API remains in use; this does not opt into Modules 2.0 beta or Expo's SwiftPM preview.

Regenerate the ignored native iOS project from the new template before rebuilding.
The earlier measurements below describe the original Expo 55 preparation and are
historical evidence, not qualification of the updated native dependencies.

**Measured for the Expo 58 update:** the ignore-scripts workspace installation
completes with one shared Expo 58.0.17 / React 19.3.0 / React Native 0.88.0
installation and ExpoModulesCore 58.0.24. Package build, package/example typechecks,
and the scoped formatting check pass. Expo configuration resolves iOS only and
deployment target 17.4. Apple autolinking resolves the package dependencies from
repository root; from the example workspace it additionally resolves
`IosVoipSDKModule`, the root `IosVoipSDK` pod, `VoIPExampleJourneyModule`, and
`VoIPExampleAppDelegateSubscriber`. No native prebuild, Pods install, Swift build,
simulator, or device was run for this dependency update.

## Prepared

- An iOS-only Expo module configuration (`platforms: ["apple"]`), root podspec and
  Swift wrapper compile the shared `Sources/` tree in place. The pod excludes the
  external injection loader, requires iOS 17.4/Swift 6, enables `CKSIM_SDK_SOURCE`,
  and reads the runtime version from canonical `VERSION`.
- The wrapper calls the agreed `@MainActor SimulatorSupport.activateIfNeeded() ->
Bool` seam through an Expo `Promise`. It exposes only internal bootstrap metadata.
  The public package entry has no provisional conversation API; RFC 0001 is M1 work.
- An Expo SDK 55 example displays native bootstrap status, errors and retry. It
  explicitly identifies call acceptance as pending. Its iOS deployment target is
  configured through `expo-build-properties`.
- npm workspaces supply one React/React Native installation for the package and
  example. The lockfile pins Expo 55.0.32, React 19.2.0 and React Native 0.83.10.
  TypeScript builds directly without the broader module-scripts toolchain.

## Measured checks

Checks ran locally with Node 26.4.0 and npm 11.17.0:

| Check                                                         | Result                                                                                                       |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `npm install --ignore-scripts --no-audit --no-fund`           | Completed; installed dependencies occupy approximately 324 MB                                                |
| `npm run build`                                               | Emits the package JavaScript and declarations                                                                |
| `npm run typecheck`                                           | Package and example pass                                                                                     |
| `npm run format:check`                                        | Passes for the scoped TypeScript/config/docs files                                                           |
| `expo config --type prebuild --json` in the example workspace | Resolves iOS-only configuration and deployment target 17.4                                                   |
| `expo-modules-autolinking resolve --platform apple --json`    | Resolves `IosVoipSDKModule`, Swift module `IosVoipSDK`, and the repository-root podspec                      |
| `pod ipc spec IosVoipSDK.podspec`                             | Parses iOS 17.4/Swift 6, the shared source patterns, resource bundle and inherited runtime macros            |
| `npm ls expo react react-native expo-modules-core --depth=1`  | One shared Expo/React/RN installation; ExpoModulesCore 55.0.27                                               |
| Metro iOS export with `--no-bytecode --max-workers 2`         | Latest export bundles 574 modules successfully (1.1 MB)                                                                             |
| `npm pack --dry-run --json`                                   | Includes the compiled internal entry, Swift wrapper, module configuration and podspec; excludes node_modules |

The first Metro export found that Babel could not resolve Expo's nested transitive
`babel-preset-expo` installation. The example now declares the matching version
55.0.25 directly; the subsequent export passed. Platform color names were checked
against the installed React Native iOS semantic-color map. Visual checks remain
pending a native build.

The preparation branch predates the tracked `VERSION` file. Pod/autolinking checks
used a temporary copy of version 0.1.1 from `codex/runtime-loader-repair`, as agreed
with the lead implementer. That copy is excluded from this scaffold commit and
removed after validation; the parent integration branch supplies canonical VERSION.

Independent spec and standards reviews found no actionable issues within this
preparation-only scope. They did not claim native build or call behavior evidence.

## Integration requirements

1. Integrate the runtime fixes and native M0 sources. The wrapper expects the
   agreed activation seam; it does not provide a substitute implementation.
2. Keep the CocoaPods resource bundle name `IosVoipSDKRuntime` when moving the
   canonical profile into `Sources/Engine/Resources/`. Resolve that bundle in the
   unified pod and use `Bundle.module` for SwiftPM.
3. Add the example's private M0 incoming ring/join fixture and verify activation
   occurs before constructing its manager. Keep full handler/state/commands API
   implementation in M1.
4. Build SwiftPM and the Expo example, then measure the incoming ring/join journey
   on a fresh simulator with no injection, locally and in CI. Verify device builds
   contain no runtime engine/hook symbols, and activation failures log and fall back
   safely.

See `Expo/README.md` and `example/README.md` for reproducible JavaScript/configuration
checks and the proposed native build commands. There are no product decisions or
RFC deviations introduced by this preparation. No license file was added.
