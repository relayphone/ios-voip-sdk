# Provider routing with several CXProviders (iPhone 13, iOS 27.0)

Measured on October 21, 2026, on the iPhone 13 test phone, iOS 27.0 (24A5355q), with genuine CallKit and no runtime. The source is `../providers.swift`. Launch it with `PROBE_MODE=providers PROBE_PROVIDERS=<scenario>`. Each scenario runs in a fresh process, which exits when it finishes.

The two providers have different configurations:

| Provider | Video | Call groups | Calls per group |
| -------- | ----- | ----------- | --------------- |
| A        | yes   | 2           | 1               |
| B        | no    | 3           | 2               |

Each provider gets its own delegate queue. A `route` row records the request's result and which providers performed the action.

## Results

| Scenario   | Setup                                             | Who receives the actions                                                                                                                                                                                               |
| ---------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `single`   | A only                                            | A (baseline)                                                                                                                                                                                                           |
| `ab`       | Create A, then B                                  | **B, for everything**: outgoing start, plus answer, mute and end on the call **A** reported. A gets only `providerDidBegin`.                                                                                           |
| `ba`       | Create B, then A                                  | **A, for everything**, including the call B reported. So the rule is order, not configuration.                                                                                                                        |
| `handles`  | A supports phone numbers only; B email only       | B, for both phone-number and email starts. Supported handle types do not route.                                                                                                                                        |
| `late`     | A has a delegate; B is created without one        | Before B's delegate is set, the request succeeds but **nobody** performs the start or end. Setting the delegate later does not replay them, and later actions go to B. **Creation, not `setDelegate`, selects the target.** |
| `drop`     | Create A and B, then release B without `invalidate` | Still B.                                                                                                                                                                                                             |
| `inv`      | Create A and B, then `invalidate` B               | Every request fails with `CXErrorCodeRequestTransactionError.unknownCallProvider` (2) after **about 10.6 s**, and A receives nothing. A can still report an incoming call, but the app cannot answer or end it. Reporting from the invalidated B succeeds and fires B's `providerDidBegin` again; requests then route to B. |
| `recreate` | Create A, `invalidate` A, then create B           | B. This is the supported way to replace a provider.                                                                                                                                                                    |

## Other observations

- **Audio callbacks.** `didActivate` and `didDeactivate` go to the receiving provider.
- **Mute echo.** Every scenario that mutes shows the same pattern:
  - Each app-requested `CXSetMutedCallAction` is followed 10–17 ms later by a second one with the same `isMuted`, a different action ID and a different transaction ID. The app did not request it.
  - Ending a muted call delivers a system `CXSetMutedCallAction(false)` after the end action. It reports `timedOutPerforming` at its 5 s deadline (5.0–5.9 s), although the probe fulfilled it immediately.
- **Teardown.** Invalidating providers at teardown produced `providerDidReset` or `providerDidBegin` on the older provider. These callbacks are not characterized further.

## Consequences

- **Runtime.** The runtime should model a per-process slot that holds the newest created provider.
  - Route all controller transactions and audio callbacks to that provider, whoever reported the call.
  - Reproduce the `unknownCallProvider` failure after invalidation.
  - Never fall back to an older provider.
  - Emit the system mute echo and the unmute after ending a muted call.
  - A strict mode should warn when an app creates a second provider, because the first one then goes silent.
- **Library.** The core must own the only `CXProvider` in the process. An adapter or vendor SDK that creates its own provider silently takes every action away from the library, including for calls the library reported.
  - To replace a provider (audio recovery), invalidate the old one before creating the new one.
  - Mute events must be idempotent.
  - A timeout on the post-end unmute is benign.
