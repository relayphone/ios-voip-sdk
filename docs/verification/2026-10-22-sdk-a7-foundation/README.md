# A7 process ownership foundation

**Measured:** [host-checks.json](host-checks.json) binds the changed sources to
host controls and compiler checks. The two duplicate SDK modules are separately
compiled optimized Swift dylibs containing the same actual Objective-C helper.
The application startup and process gate are production sources; manager and
PushKit factories are explicit host facades. Both load orders reject the second
SDK before manager two, concurrent claims preserve the owner, duplicate static
symbols fail at link time, and a startup callback can reenter the published
application. These results do not measure Apple framework routing.

The actual `iphoneos` Swift sources typecheck with Swift 6 strict concurrency
and warnings as errors in default Release and explicit diagnostics Release.
The importer uses an umbrella containing `CKRuntimeSeam.h` and
`VoIPPlatform.h`; the optional pass supplies both Swift
`-D VSSDK_ENABLE_PROVIDER_DIAGNOSTICS` and Clang
`-Xcc -DVSSDK_ENABLE_PROVIDER_DIAGNOSTICS=1`. Platform controls also compile
iOS simulator/device and watchOS headers, inspect the default Release objects,
and execute the same monitor controls with Release opt-in.

Reproduce the principal controls with:

```sh
python3 discovery/check_sdk_ownership.py
python3 discovery/check_platform_shims.py
node discovery/check_expo_plugin.cjs
python3 discovery/check_device_release.py
python3 discovery/check_sdk_m0.py
python3 discovery/check_sdk_m1.py
bash Tests/VoIPSDK/run.sh
```

The plugin needs the locked JavaScript dependencies. This worktree had none;
the initial missing-`xcode` preparation failure is retained in the receipt. Its
successful run used an existing example dependency directory through `NODE_PATH`
without installing or changing dependencies.

**Pending:** adapter identity/policy selection, typed ownership event wiring,
integrated native journeys, and a fresh pod-built Release `iphoneos` app
inspection. No simulator, device, linked application or PushKit registration
was used for this foundation. It does not complete A7 acceptance.
