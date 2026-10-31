---
status: proposed
---
# A Focus filter at its defaults is inactive

The SDK records the Focus filter state, what the app's Focus filter last asked for: unknown, inactive, or active with the filter's settings. The system runs the filter (a `SetFocusFilterIntent`) when a Focus that has it turns on, and again when that Focus turns off, with every setting reset to its default; it tells the app nothing else. So a filter whose settings equal their defaults is inactive: the defaults are the app's behaviour outside a Focus, and a Focus that keeps them asks for nothing different. Until the filter first runs the state is unknown, not inactive: the user may not have added the filter to any Focus. Inactive doesn't mean that no Focus is on: a Focus without the filter still filters the app's calls (see 0002 and 0005). The app's servers use the state to choose how each call appears (see 0006).

## Considered options
- An "enabled" setting in the filter: the user has to switch it on in every Focus, and the system resets it when the Focus turns off, as it does every other setting.
- `INFocusStatusCenter`: it needs a permission, and it reads false unless the user shares their Focus status with the app.
- Inferring a Focus from filtered calls: the app learns of it only after a call was filtered.
