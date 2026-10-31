# Contributing

Thanks for contributing. Before starting a large change, open an issue to discuss the behavior and scope. For bugs, include a minimal reproduction and the versions of iOS and Xcode that apply. Do not include push tokens, credentials, contact information or private call data.

## Setup

Use macOS 26 or later with Xcode 27.1 (Swift 6.4) and the iOS 27 SDK; the SDK supports iOS 26 and later. The [example app](Examples/CallExample) builds against this checkout; open `Examples/CallExample/CallExample.xcodeproj` and run it in an iOS 27 simulator.

## Checks

Run the host tests from the repository root:

```sh
swift test
swift format lint --strict --recursive --parallel Package.swift Sources Tests Examples Inspector tools/smoke
```

`swift format --in-place --recursive --parallel` with the same paths fixes most formatting
findings.

The call journeys need an iOS 27 simulator; the [README](README.md#testing) shows how to run them. The [SDK acceptance workflow](.github/workflows/sdk-m0.yml) defines the CI builds, the journeys and the device build inspection.

## Pull requests

Keep changes focused, describe the behavior and include the checks you ran. Add or update tests and documentation where appropriate. For public API changes, add migration notes to [CHANGELOG.md](CHANGELOG.md). Do not commit generated native projects, credentials or private device traces.

See the [code of conduct](CODE_OF_CONDUCT.md) and [security policy](SECURITY.md). This repository does not yet have a license; see the [README](README.md#license).
