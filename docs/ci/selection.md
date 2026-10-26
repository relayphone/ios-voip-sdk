# CI selection policy

Main pushes and daily SDK/Runtime runs execute every original check. Explicit manual dispatch retains full qualification. Pull requests select the serial SDK job and affected Swift, Expo, legacy, Duo routes, Runtime and helper checks. Documentation-only changes run lightweight selection and aggregate gates.

The current SDK native job retains the complete M0, M1, contracts, PushKit, system and device acceptance on one simulator. This interim split selects whole jobs; it does not shorten an SDK-native run or promise the 15-minute target. The separately qualified parallel split will restore per-journey selection after its native capture budget is resolved.

SDK workflow body or guard changes select the affected optional consumer. Changes to the shared native producer select both the legacy and Duo consumers. Inherited environment/default changes select all optional consumers. Comparison migrates only the exact guards introduced by this policy; unknown boundaries or missing jobs fail closed. New executable inputs conservatively select SDK, Runtime and helper checks.

The stable `plain-simulator` and `runtime-events` gates require every selected dependency to succeed and every unselected dependency to be skipped. A cancelled, failed or unexpectedly skipped selected job fails the aggregate. Main selects every dependency. Main concurrency groups use the commit SHA, preserving pending runs across newer pushes; PR groups use the PR ref and cancel superseded runs.

Only standard `ubuntu-latest`, `xcode-27` and `macos-26` runners are used.
