# Android JVM core

Requires JDK 17. Run `./gradlew check` from this directory (`gradlew.bat check` on Windows).
The wrapper verifies its Gradle distribution checksum. CI also validates the wrapper JAR.

- `:core` provides the v0 wire types and pure reducer. `reduce(state, input, now)`
  returns updated state and ordered effects.
  Validate configured Answer budgets against the adapter's effective deadline before use.
  Configure retention on `Budgets` to bound completed terminal records and deduplication.
  Terminal records awaiting adapter work remain available for late completions.
  `Input.Request.supported` is an interim caller-supplied flag for control requests until the
  Android runtime adopts the shared M1b capability model in `spec/capabilities.json`.
- `:runtime` serializes inputs through the reducer and dispatches its effects to system,
  authority, media and presentation ports in order. Each call owns its session, operations
  and timers. Inject a monotonic clock for deadlines and retention and a UTC clock for timestamps.
  The runtime returns media, system removal and permit release results to the reducer after
  the corresponding port calls complete.
- `:testing` runs the shared journeys through the runtime under coroutine virtual time. Fake
  ports provide confirmations with the original attempt generations.
  The core suite separately round-trips every valid model fixture and rejects every invalid one.

The Maven publications `com.relayphone:voip-core`, `com.relayphone:voip-runtime` and `com.relayphone:voip-testing` use
the root `VERSION`. The checks qualify the JVM model and behavior with fakes. Android
system, push and media adapters, device behavior and release archive delivery remain separate.
