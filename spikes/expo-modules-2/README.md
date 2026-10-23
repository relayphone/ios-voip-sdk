# Expo Modules 2.0 bridge spike

Isolated SDK 58 app for [lane #52](https://github.com/ziahamza/ios-voip-sdk/issues/52).
The app checks a cached, frozen snapshot (`@Record` + `@Union`) and coalesced
`@Event` notifications on an `@ExpoModule` class.
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
then installs and launches it on its own throwaway iPhone 17 Pro / iOS 27.0
simulator. It polls `Documents/expo2-results.json` through the app's data
container with a 60-second deadline. Every required demonstration must be present
exactly once with `pass: true`, `values` and `threads`; missing, failed, malformed
or duplicate results fail CI. Results are copied to ignored `out/` for artifacts.
The screenshot is diagnostic only. The simulator and DerivedData are deleted on
exit; remove ignored `ios/` and dependencies after a run when disk space is tight.
The app and pod require iOS 17.4.

The native snapshot is encoded and recursively frozen once per publication.
A copyable envelope returns only a retained JSI handle, preserving JS identity
and constant-time reads after initialization. Direct `@Record` return values
would re-encode the conversation list on each read. Macro 0.22's generic return
assertion requires `Copyable`, so a bare noncopyable `JavaScriptValue` cannot be
the exported return type. The typed event encoder reuses the published handle.
Typed `@Event` needs `: Module` in core 58.0.24/macros 0.22.0: the plain class
fails to compile because it lacks `EventEmitter`. All exports still use macros;
no 1.0 DSL is needed, matching Expo's [typed-event benchmark](https://github.com/expo/expo/blob/expo-modules-core%4058.0.24/packages/expo-modules-core/ios/Benchmarks/EventEmitterBenchmarks.swift#L97).

Native version updates `[1, 1, 2, 2, 3]` in one JS turn schedule one flush with
`runtime.schedule`; the listener must receive only version 3. A later duplicate
emits nothing, and version 4 emits once. Two scheduler turns drain the flush and
the asynchronous event without timing sleeps or JS-side event filtering.

## Threading and stop

Thread samples record pthread ID, main-thread status, thread name, current queue
label, and the runtime's JS-thread predicate. The default async probe samples
before and after a real suspension; a custom SDK global actor owns command state.
A named background queue emits a typed event, and its JS listener calls a sync
native probe to verify callback placement. No module instance or non-Sendable
closure crosses the queue: the emitter resolves its registered identity using
Expo's mutex-protected registry.

The benchmark checks 1,000 cached reads at both 2 and 2,048 conversations after
100 warmups. Per-read p50/p99 use nearest rank; complete batch time includes
loop/timer overhead. It asserts identity and valid samples without setting a
host-dependent latency budget. Initial encoding and publication are excluded.

See the [findings and M3.5 recommendation](../../docs/progress/2026-10-23-expo-modules-2-findings.md).
Stop after threading review. Handler/deadline/AbortSignal and remaining API checks
wait for orchestration's reply; the shipping SDK is unchanged by this spike.

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
