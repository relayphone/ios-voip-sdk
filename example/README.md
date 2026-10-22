# iOS SDK example

This Expo SDK 58 app checks the M0 native bootstrap seam and provides a private
incoming ring/join acceptance fixture. The screen shows native module loading,
the execution environment and runtime activation, with loading, error and retry
states. A successful bootstrap does not mean M0 acceptance has passed.

Install and build the package from repository root:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm run typecheck
```

The repository and example share a single npm workspace installation. The example
depends on `ios-voip-sdk` through `file:..`; Metro watches the repository and resolves
that package to the same source checkout. Keep the shared React and React Native
installation visible when changing Metro configuration.

Generate and build only iOS. Regenerate the ignored native project after the Expo
58 upgrade so the scene lifecycle replaces the legacy app delegate window setup:

```sh
npm run prebuild --workspace ios-voip-sdk-example -- --clean
npm exec --workspace ios-voip-sdk-example -- expo run:ios --configuration Release --device "$EXAMPLE_SIMULATOR_UDID"
```

Set `EXAMPLE_SIMULATOR_UDID` to a newly created simulator owned by your run, and
delete that simulator afterwards. Release mode bundles JavaScript so launch does
not depend on a Metro development server. Native projects, Pods and local Expo
state are ignored. Configure the app's deployment target through
`expo-build-properties` in `app.json`; the pod also requires iOS 17.4.

Expo 58 generates `SceneDelegate.swift` and a `UIApplicationSceneManifest`, creates
the window from its `UIWindowScene`, and preserves autolinked Expo subscribers and
the React Native factory. This is Expo's supported fix for the iOS 27 scene
lifecycle requirement. See the [migration guide](https://github.com/expo/fyi/blob/main/ios-scene-lifecycle.md)
and [supported platform/toolchain versions](https://docs.expo.dev/versions/v58.0.0/).

The app uses iOS semantic colors, a scrollable safe area, text scaling and a native
retry button. iPhone/iPad, Dark Mode and large-text visual checks are pending the
native build. No simulator or device validation is claimed by this preparation.
