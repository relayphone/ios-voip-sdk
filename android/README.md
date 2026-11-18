# Android JVM core

Requires JDK 17. Run `./gradlew check` from this directory (`gradlew.bat check` on Windows).
The wrapper verifies its Gradle distribution checksum. CI also validates the wrapper JAR.

- `:core` provides the v0 wire types and pure reducer. `reduce(state, input, instant)`
  returns updated state and ordered effects. An engine supplies the instant, executes effects,
  and feeds back confirmations and timer expirations with their original generations.
  Validate configured Answer budgets against the adapter's effective deadline before use.
  Configure retention on `Budgets` to bound completed terminal records and deduplication.
  Terminal records awaiting adapter work remain available for late completions.
  Adapters return `MediaReleased`, `SystemRemoved` or `SystemRemovalFailed`, and
  `PermitReleased` for their corresponding cleanup requests.
  `Input.Request.supported` is an interim caller-supplied flag for control requests until the
  shared M1b capability model in `spec/capabilities.json` is available.
- `:testing` runs the shared journeys against that reducer. Fake system, authority and media
  ports execute effects under coroutine virtual time. Each discovered journey runs as a test.
  The core suite separately round-trips every valid model fixture and rejects every invalid one.

The Maven publications `com.relayphone:voip-core` and `com.relayphone:voip-testing` use
the root `VERSION`. The checks qualify the JVM model and behavior with fakes. Android
system, push and media adapters, device behavior and release archive delivery remain separate.
