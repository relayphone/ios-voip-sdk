# CI selection policy

Main pushes changing only `docs/**`, `spikes/**`, Markdown or other recognized documentation files skip native jobs and retain host controls. Mixed or unknown paths, unavailable diffs, daily SDK/Runtime runs and manual dispatch execute every check. Pull requests select the SDK native group, Runtime and helper checks from the changed paths. Documentation-only changes run lightweight selection and aggregate gates. New executable inputs conservatively select SDK, Runtime and helper checks.

The stable `plain-simulator` and `runtime-events` gates require every selected dependency to succeed and every unselected dependency to be skipped. The SDK gate checks every native job before combining them into the selector's `sdk-native` group. A cancelled, failed or unexpectedly skipped selected job fails the aggregate. Main selects every dependency unless the entire push is known non-native. Main concurrency groups use the commit SHA, preserving pending runs across newer pushes; PR groups use the PR ref and cancel superseded runs.

Only standard `ubuntu-latest`, `xcode-27` and `macos-26` runners are used.
