# Android JVM foundation

Requires JDK 17. From this directory, run `./gradlew check` (Windows: `gradlew.bat check`).
The checked-in Gradle wrapper verifies its pinned distribution checksum. Kotlin, coroutines,
serialization and JUnit versions are pinned in `gradle/libs.versions.toml`.

- `:core` contains validated identities, handles, calling lines, lifecycle/action/error types,
  typed outcomes and duration policies. It has no Android framework or Android Gradle plugin dependency.
- `:testing` exposes the core and `kotlinx-coroutines-test` dependency for future deterministic fakes.
  Its tests exercise the core from a separate module under virtual time.

Constructors reject invalid values with `IllegalArgumentException`; expected operation failures
are represented by `Outcome`. Answer budgets must pass `validateFor` with the adapter's effective
deadline before use. Invitation and preparation policies cap remaining work by enclosing expiry.

The build configures Maven publications `com.relayphone:voip-core` and `com.relayphone:voip-testing`,
with the root `VERSION` and source JARs. Release archives and repository delivery are not implemented.
There is no reducer, call runtime, fake port implementation, shared-spec conformance driver,
Android system/push/media adapter, Expo/Exact binding or calling capability in these modules yet.
The JVM checks cover constructor validation, typed payloads, deadline boundaries and dependency use.
