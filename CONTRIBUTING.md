# Contributing

Thanks for contributing. Before starting a large change, open an issue to discuss the behavior and scope. For bugs, include a minimal reproduction and the versions of iOS and Xcode that apply. Do not include push tokens, credentials, contact information or private call data.

## Setup

Use macOS 26 or later with Xcode 27.1 (Swift 6.4) and the iOS 27 SDK; the SDK supports iOS 26 and later. The [example app](Examples/CallExample) builds against this checkout; open `Examples/CallExample/CallExample.xcodeproj` and run it in an iOS 27 simulator.

## Checks

Run the tests as the [README](README.md#running-the-tests) shows, and check the formatting:

```sh
swift format lint --strict --recursive --parallel Package.swift Sources Tests Examples Inspector tools/smoke
```

`swift format --in-place --recursive --parallel` with the same paths fixes most findings.

The TypeScript tools in `tools/` build, package and smoke-test the standalone simulator runtime.
They run with Node.js 24 and need no build step; `npm ci`, `npx tsc --project .` and `node --test`
in `tools/` check them.

The [CI workflow](.github/workflows/ci.yml) runs all of these, builds every library and the
example for devices and the simulator, checks that the example's device build leaves out the
simulator runtime and CallKit, builds the documentation and the Inspector, and smoke-tests a
built runtime package. The [release workflow](.github/workflows/runtime-release.yml)
qualifies the simulator runtime package and publishes it with each release.

## Pull requests

Keep changes focused, describe the behavior and include the checks you ran. Add or update tests and documentation where appropriate. For public API changes, add migration notes to [CHANGELOG.md](CHANGELOG.md). Do not commit generated native projects, credentials or private device traces.

See the [code of conduct](CODE_OF_CONDUCT.md) and [security policy](SECURITY.md). This repository does not yet have a license; see the [README](README.md#license).
