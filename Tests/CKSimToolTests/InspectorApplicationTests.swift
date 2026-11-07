#if os(macOS)
  import Foundation
  import Testing

  @testable import CKSimTool

  struct InspectorApplicationTests {
    private struct Info: Encodable {
      let platforms: [String]?
      let executable: String?
      enum CodingKeys: String, CodingKey {
        case platforms = "CFBundleSupportedPlatforms"
        case executable = "CFBundleExecutable"
      }
    }

    private func bundle(in root: URL, macLayout: Bool, platforms: [String]?, executable: String?)
      throws -> URL
    {
      let bundle = root.appending(path: "Inspector.app")
      let directory = macLayout ? bundle.appending(path: "Contents") : bundle
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      try encoder.encode(
        Info(platforms: platforms, executable: executable)
      )
      .write(to: directory.appending(path: "Info.plist"))
      return bundle
    }

    @Test func macPlatformComesFromTheBundlePlatforms() throws {
      let scratch = try Scratch()
      let url = try bundle(
        in: scratch.url, macLayout: true, platforms: ["MacOSX"], executable: "CKSimInspector")
      let app = try InspectorApplication(bundle: url)
      #expect(app.platform == .macOS)
      #expect(app.executable == url.appending(path: "Contents/MacOS/CKSimInspector"))
      let environment = app.environment(
        url: "http://127.0.0.1:1234", token: "fixture-token",
        inherited: ["PATH": "/bin", "CKSIM_INSPECTOR_TOKEN": "stale"])
      #expect(environment["PATH"] == "/bin")
      #expect(environment["CKSIM_INSPECTOR_URL"] == "http://127.0.0.1:1234")
      #expect(environment["CKSIM_INSPECTOR_TOKEN"] == "fixture-token")
      #expect(environment["SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN"] == nil)
    }

    @Test(arguments: [nil, ["iPhoneSimulator"]])
    func simulatorBundlesKeepTheSimctlEnvironment(platforms: [String]?) throws {
      let scratch = try Scratch()
      let url = try bundle(
        in: scratch.url, macLayout: false, platforms: platforms, executable: "CKSimInspector")
      let app = try InspectorApplication(bundle: url)
      #expect(app.platform == .simulator)
      #expect(app.executable == nil)
      let environment = app.environment(
        url: "http://127.0.0.1:1234", token: "fixture-token", inherited: ["PATH": "/bin"])
      #expect(environment["PATH"] == "/bin")
      #expect(environment["SIMCTL_CHILD_CKSIM_INSPECTOR_URL"] == "http://127.0.0.1:1234")
      #expect(environment["SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN"] == "fixture-token")
      #expect(environment["CKSIM_INSPECTOR_TOKEN"] == nil)
    }

    @Test(arguments: [nil, "", "../other", ".", ".."]) func invalidMacExecutablesAreRejected(
      executable: String?
    ) throws {
      let scratch = try Scratch()
      let url = try bundle(
        in: scratch.url, macLayout: true, platforms: ["MacOSX"], executable: executable)
      #expect(throws: CKSimError.self) { try InspectorApplication(bundle: url) }
    }
  }
#endif
