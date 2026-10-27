# CI selection policy

Main pushes changing only `docs/**`, `spikes/**`, Markdown or other recognized documentation files skip native jobs and retain host controls. Mixed or unknown paths, unavailable diffs, daily SDK/Runtime runs and manual dispatch execute every original check. Pull requests select the SDK native group and affected Swift, Expo, legacy, Duo routes, Runtime and helper checks. Documentation-only changes run lightweight selection and aggregate gates.

The SDK native group runs host controls and independent source-bound builds in parallel. Each selected journey group uses its own simulator. PRs run the critical M1 journeys and groups affected by the change; shared simulator, SDK or workflow inputs conservatively select every group. Native-affecting main pushes and nightly runs retain the complete M0, M1, contracts, PushKit, system and device acceptance.

SDK workflow body or guard changes select the affected optional consumer. Changes to the shared fixture producer select both the legacy and Duo consumers. Inherited environment/default changes select all optional consumers. Comparison migrates only the exact guards introduced by this policy; unknown boundaries or missing jobs fail closed. New executable inputs conservatively select SDK, Runtime and helper checks.

The stable `plain-simulator` and `runtime-events` gates require every selected dependency to succeed and every unselected dependency to be skipped. The SDK gate checks every native shard before combining it into the selector's `sdk-native` group. A cancelled, failed or unexpectedly skipped selected job fails the aggregate. Main selects every dependency unless the entire push is known non-native. Main concurrency groups use the commit SHA, preserving pending runs across newer pushes; PR groups use the PR ref and cancel superseded runs.

The SDK aggregate summary reports elapsed workflow time to the summary, current-attempt job execution and created-to-started queue proxies. Skipped or unavailable times are marked unknown, and report failures do not alter the acceptance gate.

Only standard `ubuntu-latest`, `xcode-27` and `macos-26` runners are used.
