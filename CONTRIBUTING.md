# Contributing

Thanks for contributing. Before starting a large change, open an issue to discuss the behavior and scope. For bugs, include a minimal reproduction and the versions of iOS, Xcode, Node and Expo that apply. Do not include push tokens, credentials, contact information or private call data.

## Setup

Use macOS with Xcode 27.1 and the iOS 27 SDK for native builds; the SDK supports iOS 17.4 and later. The Expo example uses Node 24 and CocoaPods. Install JavaScript dependencies from the repository root:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
```

The root package and example share the npm workspace. See the [example guide](example/README.md) for generating the iOS project and running it in a simulator.

## Checks

Run the fast JavaScript and configuration checks from the repository root:

```sh
npm run typecheck
npm run format:check
node --test Expo/tests/m1-runtime.test.cjs
```

Native SDK builds and simulator journeys require Xcode and an installed iOS simulator runtime. The [SDK acceptance workflow](.github/workflows/sdk-m0.yml) defines the CI builds and device-code inspections; the [Expo guide](Expo/README.md#validation) lists additional local checks. These JavaScript checks alone do not establish that native calling works. Some tests still use dedicated fixtures and scripts; `swift test` is not yet the complete test suite.

## Pull requests

Keep changes focused, describe the behavior and include the checks you ran. Add or update tests and documentation where appropriate. For public API changes, add migration notes to [CHANGELOG.md](CHANGELOG.md). Do not commit generated native projects, credentials or private device traces.

See the [code of conduct](CODE_OF_CONDUCT.md) and [security policy](SECURITY.md). This repository does not yet have a license; see the [README](README.md#license).
