#if os(macOS)
  import Foundation

  /// The two supported Inspector bundle layouts and their bridge launch environments.
  struct InspectorApplication {
    enum Platform: Equatable, Sendable { case macOS, simulator }
    let platform: Platform
    let executable: URL?

    init(bundle: URL) throws {
      struct Info: Decodable {
        let platforms: [String]?
        let executable: String?
        enum CodingKeys: String, CodingKey {
          case platforms = "CFBundleSupportedPlatforms"
          case executable = "CFBundleExecutable"
        }
      }
      let contents = bundle.appending(path: "Contents")
      let macInfo = contents.appending(path: "Info.plist")
      let infoURL =
        FileManager.default.fileExists(atPath: macInfo.path())
        ? macInfo : bundle.appending(path: "Info.plist")
      let info = try PropertyListDecoder().decode(Info.self, from: Data(contentsOf: infoURL))
      if info.platforms?.contains("MacOSX") == true {
        guard let name = info.executable, !name.isEmpty, !name.contains("/"),
          name != ".", name != ".."
        else { throw CKSimError("The Mac Inspector bundle has no valid executable name.") }
        platform = .macOS
        executable = contents.appending(path: "MacOS").appending(path: name)
      } else {
        platform = .simulator
        executable = nil
      }
    }

    func environment(url: String, token: String, inherited: [String: String]) -> [String: String] {
      let prefix = platform == .macOS ? "" : "SIMCTL_CHILD_"
      return inherited.merging([
        "\(prefix)CKSIM_INSPECTOR_URL": url,
        "\(prefix)CKSIM_INSPECTOR_TOKEN": token,
      ]) { $1 }
    }
  }
#endif
