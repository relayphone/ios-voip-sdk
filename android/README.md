# Android calling modules

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
- `:system` adapts AndroidX Core-Telecom to `SystemPort` on API 26 and later. Register
  `AndroidTelecomSystem` with the highest API level that should use the legacy backend
  and route its inputs to `CallRuntime.submit`. Use `AndroidTelecomSystem.answer`
  for app Answer requests so they share a receipt with the system callback. Submit
  Start and End through the runtime. Core-Telecom admission, logical End and observed
  system removal have separate results.
- `:testing` runs the shared journeys through the runtime under coroutine virtual time. Fake
  ports provide confirmations with the original attempt generations.
  The core suite separately round-trips every valid model fixture and rejects every invalid one.

The Maven publications `com.relayphone:voip-core`, `com.relayphone:voip-runtime`,
`com.relayphone:voip-system` and `com.relayphone:voip-testing` use the root `VERSION`.
Install Android SDK 37.0 and Build Tools 36.0.0 to build the system module. Emulator
instrumentation uses compatibility bound 34 to exercise legacy Telecom on API 34 and
transactional Telecom on API 35.
