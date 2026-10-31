#if os(macOS)
  import Foundation
  import Testing

  @testable import CKSimTool

  /// The simulator-wide loader: what `install` changes and what `uninstall` and `repair` restore.
  struct InstallationTests {
    private let scratch: Scratch
    private let simulator = FakeSimulator()
    private let package: URL
    private let installation: Installation

    init() throws {
      scratch = try Scratch()
      package = try makePackage(in: scratch.url)
      installation = Installation(
        simctl: simulator.simctl, device: device,
        stateDirectory: scratch.url.appending(path: "state"))
    }

    private var loader: String {
      package.appending(path: "CKSimLoader.dylib").path(percentEncoded: false)
    }

    @Test func installAppendsTheLoaderAndUninstallRestoresTheEnvironment() throws {
      simulator.set("DYLD_INSERT_LIBRARIES", "/opt/other.dylib")
      let result = try installation.install(runtime: package, bundle: bundle)
      #expect(result["bundles"] as? [String] == [bundle])
      #expect(simulator.environment["DYLD_INSERT_LIBRARIES"] == "/opt/other.dylib:\(loader)")
      #expect(simulator.environment["CKSIM_BUNDLE_IDS"] == bundle)
      #expect(simulator.environment["CKSIM_ENABLED"] == "1")
      #expect(simulator.environment["CKSIM_PROFILE"] == "ios-27.0")
      let mode =
        try FileManager.default.attributesOfItem(
          atPath: installation.stateFile.path())[.posixPermissions] as? NSNumber
      #expect(mode?.intValue == 0o600)

      _ = try installation.install(runtime: package, bundle: "dev.example.second")
      #expect(simulator.environment["CKSIM_BUNDLE_IDS"] == "dev.example.app,dev.example.second")
      #expect(simulator.environment["DYLD_INSERT_LIBRARIES"] == "/opt/other.dylib:\(loader)")

      _ = try installation.uninstall()
      #expect(simulator.environment == ["DYLD_INSERT_LIBRARIES": "/opt/other.dylib"])
      #expect(!FileManager.default.fileExists(atPath: installation.stateFile.path()))
    }

    @Test func installRefusesAnotherReleaseOrAnExternalChange() throws {
      _ = try installation.install(runtime: package, bundle: bundle)
      let other = try makePackage(in: scratch.url.appending(path: "other"))
      #expect(
        throws: CKSimError("Uninstall the existing runtime before selecting another release.")
      ) {
        try installation.install(runtime: other, bundle: bundle)
      }
      simulator.set("CKSIM_PROFILE", "edited")
      #expect(throws: CKSimError.self) {
        try installation.install(runtime: package, bundle: bundle)
      }
      #expect(throws: CKSimError.self) { try installation.uninstall() }
    }

    @Test func repairWithoutAnInstallationChangesNothing() throws {
      let result = try installation.repair()
      #expect(result["repaired"] as? Bool == false)
      #expect(simulator.calls.isEmpty)
    }

    @Test func repairRemovesOnlyTheRecordedLoaderEntry() throws {
      simulator.set("DYLD_INSERT_LIBRARIES", "/opt/before.dylib")
      _ = try installation.install(runtime: package, bundle: bundle)
      // Another injector appends its own entry after the installation.
      simulator.set("DYLD_INSERT_LIBRARIES", "/opt/before.dylib:\(loader):/opt/after.dylib")
      // The package was deleted; repair needs neither it nor the bundle.
      try FileManager.default.removeItem(at: package)
      let result = try installation.repair()
      #expect(result["repaired"] as? Bool == true)
      #expect(
        simulator.environment == ["DYLD_INSERT_LIBRARIES": "/opt/before.dylib:/opt/after.dylib"])
      #expect(
        try installation.repair()["repaired"] as? Bool == false, "Repairing again does nothing")
    }

    @Test func repairUnsetsTheLoaderItAloneAdded() throws {
      _ = try installation.install(runtime: package, bundle: bundle)
      _ = try installation.repair()
      #expect(simulator.environment.isEmpty)
    }

    @Test func repairRefusesAnAmbiguousEditWithoutWriting() throws {
      _ = try installation.install(runtime: package, bundle: bundle)
      simulator.set("CKSIM_RUNTIME", "/elsewhere/CKSimRuntime.dylib")
      let before = simulator.environment
      #expect(throws: CKSimError.self) { try installation.repair() }
      #expect(simulator.environment == before)
      #expect(FileManager.default.fileExists(atPath: installation.stateFile.path()))

      simulator.set(
        "CKSIM_RUNTIME", package.appending(path: "CKSimRuntime.dylib").path(percentEncoded: false))
      simulator.set("DYLD_INSERT_LIBRARIES", "\(loader):\(loader)")
      #expect(throws: CKSimError.self) { try installation.repair() }
    }

    @Test func repairRefusesAnInvalidRecord() throws {
      try FileManager.default.createDirectory(
        at: installation.stateDirectory, withIntermediateDirectories: true)
      try Data("[]".utf8).write(to: installation.stateFile)
      #expect(throws: CKSimError.self) { try installation.repair() }
      try JSONSerialization.data(withJSONObject: [
        "runtime": "relative", "bundles": [bundle],
        "original": Dictionary(uniqueKeysWithValues: Installation.keys.map { ($0, NSNull()) }),
        "applied": Dictionary(uniqueKeysWithValues: Installation.keys.map { ($0, "x") }),
      ]).write(to: installation.stateFile)
      #expect(throws: CKSimError.self) { try installation.repair() }
    }
  }
#endif
