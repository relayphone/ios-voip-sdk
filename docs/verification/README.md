# Verification

Tests consume [synthetic fixtures](../../discovery/fixtures/), [provider-routing traces](../research/callkit-simulator-probe/provider-routing/), [LCK traces](../research/callkit-simulator-probe/livecommunicationkit/) and the references listed in [discovery](../../discovery/README.md).

Fresh acceptance runs retain their outputs in GitHub Actions: [SDK](https://github.com/ziahamza/ios-voip-sdk/actions/workflows/sdk-m0.yml), [runtime](https://github.com/ziahamza/ios-voip-sdk/actions/workflows/simulator-discovery.yml) and [release](https://github.com/ziahamza/ios-voip-sdk/actions/workflows/runtime-release.yml).

Historical receipts and logs remain in [Git history](https://github.com/ziahamza/ios-voip-sdk/tree/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification) and the linked PRs. They are not test inputs. Keep new run outputs out of version control.
