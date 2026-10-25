# Simulator infrastructure failures

Only linked CI observations belong here. A recovered infrastructure retry stays
visible in the job summary; it does not qualify a failed product assertion.

| Date (UTC) | Workflow | Step | Observation and retry result | CI evidence |
| --- | --- | --- | --- | --- |
| 2026-10-24 | sdk-m0 | launch | NSPOSIX 3, no process handle or app evidence; no automatic recovery recorded. | [Main attempt 2](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40085930870/attempts/2) |
| 2026-10-24 | sdk-m0 | installed paths | Pre-launch container lookup frontier; exit 142. Removed by #91. The exact bundle and service cause were not established. | [Main](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40095919509) |
| 2026-10-24 | runtime-m4 | install | First fixture installation timed out before app launch; diagnostic RPCs also timed out. | [Main](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40109610991) |
| 2026-10-24 | sdk-m0 | journal capture | Legacy app completed; post-native data-container lookup timed out after 30 seconds. | [Main](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40109611000) |
| 2026-10-25 | sdk-m0 | install | First example installation timed out after 180 seconds; bootstatus had passed. A controlled workflow retry was requested by lane #66. | [PR #92](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40146100908) |
| 2026-10-25 | runtime-m4 | install | First fixture installation timed out after 120 seconds before app launch; one controlled workflow retry recovered. | [PR #92](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40146100926) |
| 2026-10-25 | sdk-m0 | privacy | Swift LiveKit microphone permission call timed out after 60 seconds before the mode loop. Lane #50 notified to choose its controlled retry or revert. | [Main](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40149073833/job/121036570747) |
| 2026-10-25 | runtime-m4 | install | First fixture installation exceeded 120 seconds before app launch in both attempts; the one workflow retry was exhausted. Attempt 1 also had an unspecified 30-second cleanup failure; attempt 2 acknowledged shutdown/delete without independent absence evidence. | [Attempt 1](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40181157344/attempts/1), [attempt 2](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40181157344/attempts/2) |
| 2026-10-25 | runtime-m4 | install bound | Two independent cold installs completed in 124.051 and 112.653 seconds under a 600-second observation ceiling; the production bound becomes 180 seconds. No app launch or retry. Sample 1 shutdown timed out, but both deletes and independent absence checks succeeded. | [Hosted measurements](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40197286743) |
| 2026-10-25 | sdk-m0 | privacy | Main run 40208026717: create, boot and install succeeded; microphone permission timed out after 60 seconds before any Swift case or app launch. Owned cleanup reported success. The one controlled workflow retry is pending; no recovery recorded. | [Main failure](https://github.com/ziahamza/ios-voip-sdk/actions/runs/40208026717) |
