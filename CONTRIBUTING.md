# Contributing

Thanks for contributing. Before starting a large change, open an issue to discuss the behavior and scope. For bugs, include a minimal reproduction and the versions of iOS and Xcode that apply. Do not include push tokens, credentials, contact information or private call data.

## Setup

Use Node.js 24 for the Expo package and TypeScript tools. From the repository root, the Expo checks on Linux are

```sh
npm ci --prefix expo --ignore-scripts --no-audit --no-fund
npm run typecheck --prefix expo
npm run test:linux --prefix expo
```

The [Expo workflow](.github/workflows/expo.yml) runs these checks on Ubuntu. On macOS, `npm test --prefix expo` runs the full suite, including the Ruby, CocoaPods and Xcode checks. See the [Android checks](android/README.md#checks) for running the JVM tests with JDK 17.

For Swift development, use macOS 26 or later with Xcode 27.1 (Swift 6.4) and the iOS 27 SDK. The SDK supports iOS 26 and later. The [example app](Examples/CallExample) builds against this checkout. Open `Examples/CallExample/CallExample.xcodeproj` and run it in an iOS 27 simulator.

## Checks

Run the tests as the [README](README.md#running-the-tests) shows, and check the formatting:

```sh
swift format lint --strict --recursive --parallel Package.swift Sources Tests Examples Inspector tools/smoke exact/apple
```

`swift format --in-place --recursive --parallel` with the same paths fixes most findings.

The TypeScript tools in `tools/` build, package and smoke-test the standalone simulator runtime.
They run with Node.js 24 and need no build step. From `tools/`, run:

```sh
npm ci
npm ci --prefix media-test
npm run typecheck
npm test
npm run lint
```

The lint command covers `tools/`, `expo/` and `exact/`.

The [CI workflow](.github/workflows/ci.yml) runs all of these, builds every library and the
example for devices and the simulator, checks that the example's device build leaves out the
simulator runtime and CallKit, builds the documentation and the Inspector, and smoke-tests a
built runtime package. The [release workflow](.github/workflows/runtime-release.yml)
qualifies the simulator runtime package and publishes it with each release.

On pull requests, the Public API compatibility job runs
`swift package diagnose-api-breaking-changes` against the `v`-prefixed release tag in `VERSION`
for the iOS library products. Its summary lists API breaks. Before 1.0, an intentional break
requires a `### Breaking` heading under `## Unreleased` in `CHANGELOG.md`, with migration notes;
otherwise the job fails. Build and comparison-tool errors always fail, even with that heading.

## Simulator tests

CI boots its simulator and waits for boot completion before running the tests. If the test
runner hangs before connecting and the result bundle reports zero failed tests, CI deletes the
simulator and runs the suites once more on a fresh, fully booted simulator. Failed tests are
never retried. The standalone runtime check uses the simulator on which the suites passed, and
cleanup runs even after a failure.

The job summary says `ok` for a first-attempt pass, `infra:runner-hang (retried, passed)` or
`infra:runner-hang (retried, failed)` for a qualifying hang, or `product:tests (<n> failed)` for
a test failure. If the failed run has no readable test count, the count is `unknown` and it is
not retried. A successful infrastructure retry leaves the job green while preserving its label.

## Pull requests

Keep changes focused, describe the behavior and include the checks you ran. Add or update tests and documentation where appropriate. For public API changes, add migration notes to [CHANGELOG.md](CHANGELOG.md). Do not commit generated native projects, credentials or private device traces.

See the [code of conduct](CODE_OF_CONDUCT.md) and [security policy](SECURITY.md). Contributions are licensed under the repository's [MIT license](LICENSE).
