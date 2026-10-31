# SDK acceptance jobs

The SDK workflow runs independent jobs in parallel:

| Job | Runner | What it checks |
| --- | --- | --- |
| `offline-controls` | Ubuntu | The simulator helper and CI policy unit tests, the Node tool tests, and the runtime CLI and console launcher controls. |
| `apple-host-controls` | Xcode | `swift test` on the macOS host and the runtime's push launch controls. |
| `sdk-example` | Xcode | Builds `Examples/CallExample` for the simulator in Debug and for devices in Release, then checks that the device build contains neither the simulator runtime nor CallKit. |
| `sdk-core` | Xcode | Evaluates the CocoaPods spec and builds every library for iOS devices and the simulator in Release. |
| `simulator-journeys` | Xcode | Runs the call journeys through both calling framework adapters on an owned iOS 27 simulator, with the CallKit adapter's tests. |

The stable `plain-simulator` gate requires every selected job to succeed and every unselected
job to be skipped; skipped, cancelled or failed selected jobs fail it. Its summary reports
elapsed workflow time, job execution and queue proxies; a report failure doesn't change the gate.

Diagnostic artifacts include the attempt in their name and expire after three days. An upload
has an eight-minute bound and one retry.
