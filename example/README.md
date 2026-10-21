# iOS SDK example

This Expo SDK 55 app currently checks the M0 native bootstrap seam. The screen
shows native module loading, the execution environment and runtime activation,
with loading, error and retry states. The incoming ring/join journey is pending
native integration. A successful bootstrap does not mean M0 acceptance has passed.

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

After the shared native runtime and SDK have been integrated, generate and build
only iOS:

```sh
npm run prebuild --workspace ios-voip-sdk-example
npm exec --workspace ios-voip-sdk-example -- expo run:ios --configuration Release --device "$EXAMPLE_SIMULATOR_UDID"
```

Set `EXAMPLE_SIMULATOR_UDID` to a newly created simulator owned by your run, and
delete that simulator afterwards. Release mode bundles JavaScript so launch does
not depend on a Metro development server. Native projects, Pods and local Expo
state are ignored. Configure the app's deployment target through
`expo-build-properties` in `app.json`; the pod also requires iOS 17.4.

The app uses iOS semantic colors, a scrollable safe area, text scaling and a native
retry button. iPhone/iPad, Dark Mode and large-text visual checks are pending the
native build. No simulator or device validation is claimed by this preparation.
