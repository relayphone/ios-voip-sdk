# Expo Modules 2.0 bridge spike

Isolated SDK 58 app for [lane #52](https://github.com/ziahamza/ios-voip-sdk/issues/52).
The scaffold calls one synchronous `@JS` greeting on a plain `@ExpoModule` class.
It does not depend on the production SDK or change its bridge.

## Run the scaffold

Use Node 24.3+ (or Node 22.13+ / 26+), CocoaPods, and a Swift 6.2+ toolchain.
The local reference is Xcode 27.1 / Swift 6.4 with an iPhone 17 Pro on iOS 27.0.
Expo Go cannot load this local native module.

```sh
cd spikes/expo-modules-2
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck
bash scripts/smoke-ios.sh
```

The smoke script generates iOS sources, installs pods, bundles a Release app,
then installs and launches it on its own throwaway simulator. Check
`out/scaffold.png` for the native greeting. It deletes its simulator and
DerivedData on exit; `out/`, `ios/` and dependencies are ignored. Remove the
remaining generated directories after a run when disk space is tight.
`npm run ios -- --device <your-own-simulator-UUID>` is available for iteration.
The scaffold smoke is a launch check, not acceptance for demonstrations 1–4.

## Proposed next slices

1. Immutable `@Record` / `@Union` conversation fixtures and a cached, O(1)
   synchronous snapshot with a version; introduce the branded TypeScript ID.
2. One `@Event` change payload containing snapshot and version, coalesced by
   version. Assert payloads and event counts from JavaScript.
3. Async commands on a custom SDK global actor; record thread placement before
   and after suspension alongside the default `@JavaScriptActor` behavior.
4. Await an async JS handler with a deadline Task and cancellation mapped to an
   `AbortSignal`; compare a value-returning JS closure's blocking behavior.
5. Evaluate `scan-exports` for TypeScript drift, `@Event` on `@SharedObject`, and
   the app delegate subscriber's early PushKit registration. Simulator results
   cannot establish physical-device PushKit timing.

Automate slices 1–4 on an iOS 27.0 simulator before claiming bridge acceptance.
The final findings note and M3.5 recommendation follow those demonstrations;
its requested location outside this lane's owned directory needs coordination.

## Research used for the scaffold

- [Expo's September 8 introduction](https://expo.dev/blog/an-early-look-at-expo-modules-2-0)
  describes the plain Swift class and incremental coexistence with the 1.0 DSL.
- [Macro API at v0.22.0](https://github.com/expo/expo-modules-macros/tree/v0.22.0)
  defines the compiler-checked bindings and scanner. The locked SDK installs it
  transitively through `expo-modules-core`; no separate plugin build is needed.
- [SDK 58 pod integration](https://github.com/expo/expo/blob/sdk-58/packages/expo-modules-autolinking/scripts/ios/project_integrator.rb)
  adds the macro executable to pods with a direct `ExpoModulesCore` dependency.
- [Steering §B](../../docs/progress/2026-10-22-claude-steering.md#b-bridge-and-threading-direction-decide-now-while-the-js-surface-is-small)
  supplies the threading contract: async `@JS` defaults to the JS actor until
  its first suspension; command isolation must be explicit. Value-returning JS
  closures block native callers; the handler must use an async closure.
