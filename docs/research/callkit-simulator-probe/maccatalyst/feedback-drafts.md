# Feedback Assistant drafts (for Hamza to file)

Two separate reports. File each as **macOS → Developer Technologies & SDKs**, or **CallKit** / **LiveCommunicationKit** if those areas are listed.

---

## 1. callservicesd aborts when a Mac Catalyst CallKit app's LaunchServices record is missing

**Title:** callservicesd crashes (SIGABRT, nil dictionary key) when a Mac Catalyst app using CallKit runs while its LaunchServices record is missing or being replaced

**Environment:** macOS 27.0.1 (26A434), Xcode 27.1, MacBook Pro (Apple silicon). The app is Mac Catalyst, sandboxed, with the `voip` background mode, and was run from `~/Applications`.

**Description:**

When a Mac Catalyst app creates a `CXProvider` and reports an incoming call or requests a transaction, `callservicesd` asks LaunchServices for the app's record.

- **App never registered** (for example, run from a temporary build folder): the lookup fails with `NSOSStatusErrorDomain -10814`. `callservicesd` then logs "Denying creation of CXXPCCallSource … bundleIdentifier: (null) … hasVoIPBackgroundMode: 0". The app gets `CXErrorCodeRequestTransactionError.unentitled` and a generic `CXErrorDomain` 0 error. That is a confusing diagnosis for a lookup failure, but survivable.
- **App replaced and re-registered between launches** (`lsregister -u`, copy a rebuilt bundle, `lsregister -f`, launch with `open`): `callservicesd` **crashed twice**. Two crashes in two attempts suggests the crash is reproducible.
  - **Crash:** `EXC_CRASH (SIGABRT)`, "abort() called". An Objective-C exception was thrown from `-[__NSDictionaryM setObject:forKeyedSubscript:]` inside `callservicesd` (offsets `0xbd944`, `0xbd520`, `0x23ad0c`).
  - **Likely cause:** a nil key, presumably the nil bundle identifier from the failed lookup.
  - **Recovery:** launchd restarted the daemon, which briefly interrupts system calling services (FaceTime and Continuity).

**Steps to reproduce:**

1. Build a minimal Mac Catalyst app that creates a `CXProvider` with a delegate, then calls `CXCallController.request` with a `CXStartCallAction` and `reportNewIncomingCall`.
2. Copy it to `~/Applications/Probe.app`, run `lsregister -f`, launch with `open`, and let it run.
3. Rebuild with a different code signature (ad hoc, then Apple Development). Run `lsregister -u` on the old copy, delete it, copy the new build in, run `lsregister -f`, and immediately `open` it.
4. Check `~/Library/Logs/DiagnosticReports/callservicesd-*.ips`.

**Expected:** a missing or stale LaunchServices record yields a clear error to the client, and `callservicesd` keeps running.

**Actual:** `callservicesd` aborts.

**Attach:**

- `~/Library/Logs/DiagnosticReports/callservicesd-2026-10-21-215833.ips` and `callservicesd-2026-10-21-215859.ips`;
- a sysdiagnose, if you reproduce it again.

---

## 2. LiveCommunicationKit (Mac Catalyst) is missing the audio delegate requirements its Swift interface declares

**Title:** Mac Catalyst apps cannot conform to `ConversationManagerDelegate`: link fails on missing method descriptors for `didActivate` / `didDeactivate`

**Environment:** Xcode 27.1, macOS 27.0 SDK (`MacOSX27.0.sdk`), destination `platform=macOS,variant=Mac Catalyst`. The runtime is macOS 27.0.1 (26A434).

**Description:**

The Catalyst Swift interface `LiveCommunicationKit.swiftmodule/arm64e-apple-ios-macabi.swiftinterface` declares two `ConversationManagerDelegate` requirements:

- `conversationManager(_:didActivate:)`
- `conversationManager(_:didDeactivate:)`

Neither the SDK's `LiveCommunicationKit.tbd` (targets include `arm64e-maccatalyst`) nor the framework shipped in macOS 27.0.1 exports the method descriptors or dispatch thunks for them. They have 12 `ConversationManagerDelegate` symbols; the iOS 27.1 SDK has 16.

Every conformance's witness table references all requirements, so **any Mac Catalyst type conforming to `ConversationManagerDelegate` fails to link**. A Catalyst app therefore cannot receive LiveCommunicationKit actions, even though the documentation lists Mac Catalyst 17.4 and later.

**Steps to reproduce:** a Mac Catalyst target that conforms to `ConversationManagerDelegate`, implementing all seven requirements, and builds for `platform=macOS,variant=Mac Catalyst`.

**Expected:** the app links. Either the requirements are exported, or the interface omits them on Catalyst and states that audio activation callbacks aren't delivered there.

**Actual:**

```text
Undefined symbols for architecture arm64:
  "method descriptor for LiveCommunicationKit.ConversationManagerDelegate.conversationManager(_: LiveCommunicationKit.ConversationManager, didActivate: __C.AVAudioSession) -> ()"
  "method descriptor for LiveCommunicationKit.ConversationManagerDelegate.conversationManager(_: LiveCommunicationKit.ConversationManager, didDeactivate: __C.AVAudioSession) -> ()"
```

**Related observation:** genuine CallKit on Mac Catalyst also delivered no `provider(_:didActivate:)` callbacks for an outgoing call.
