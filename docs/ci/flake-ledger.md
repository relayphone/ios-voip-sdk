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
