---
status: proposed
---
# Call notifications never ring

When the system filters an incoming call, or the app shows it only as a call preview, the SDK can post a communication notification for the caller: one per call, at the passive or active interruption level, with the default sound or none, and never for a block-listed caller or a call that rings. The system then applies the user's Focus: a banner for the people the Focus allows, and only Notification Center for everyone else (3 of 3 tries each on an iPhone 13 running iOS 27.1). The SDK offers no Time Sensitive or Critical level and no custom sound. With a Focus's Time Sensitive switch on, a time-sensitive notification broke through for a caller the Focus doesn't allow (3 of 3 tries), which overrides the user's Focus as presenting a filtered call again would (see 0005). When a filtered call ends without being joined here, the SDK replaces its notification with a missed-call notification by default, and the app can keep, replace or remove it instead.

## Considered options
- Any interruption level the app chooses: one option undoes the user's Focus.
- Time Sensitive for callers the app chooses: the same breakthrough, and a risk in App Review.
