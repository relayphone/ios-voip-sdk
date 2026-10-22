# Process owner core preparation

**Measured:** [host-checks.json](host-checks.json) binds the focused core sources
and nine host/compiler verification entries. Two separately compiled optimized
SDK dylibs execute the real application, factory, one-shot setup, Swift image
identity and Objective-C process claim. Both load orders refuse SDK two before
its manager-construction boundary; concurrent claims, configuration conflicts,
reentrant publication and real static duplicate-symbol failure also pass.
Manager and PushKit construction/observation are explicit host facades.

A genuine SwiftPM Release `iphoneos` library build passed, with ten products
hashed and owned DerivedData removed. Four existing manager region-isolation
warning lines remain. The process helper compiles for watchOS 10.4. This result
qualifies source compilation, not a native application or duplicate linkage in
a shipping app. TypeScript recognizes the native duplicate-linkage error and
rejects unknown codes in the runtime guard.

Principal reproduction commands:

```sh
python3 discovery/check_sdk_ownership.py
python3 discovery/check_device_release.py
python3 discovery/check_sdk_m1.py
python3 discovery/check_sdk_m1_contracts.py
npm run typecheck
node --test Expo/tests/m1-runtime.test.cjs
```

No simulator, device, native app launch, APNs, PushKit registration, hosted CI or
publication was used. The final A0.1 correction and its qualification remain
required before publication. Optional Release diagnostics and M2 media/audio
remain on their separate integration stack.
