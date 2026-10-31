#if os(macOS)
  import Foundation

  /// The optional simulator-wide loader: `install` appends the package's loader to the
  /// simulator's launchd environment for the named bundles, and records the values it replaced so
  /// that `uninstall` and `repair` can restore them.
  struct Installation {
    static let keys = [
      "DYLD_INSERT_LIBRARIES", "CKSIM_RUNTIME", "CKSIM_BUNDLE_IDS", "CKSIM_ENABLED",
      "CKSIM_PROFILE",
    ]

    /// What an installation recorded, in `~/.local/state/callkit-simulator/<simulator>.json`.
    struct State: Codable {
      var runtime: String
      var bundles: [String]
      var original: [String: String?]
      var applied: [String: String?]
      /// Every value a key may hold while an installation is being written.
      var recoverable: [String: [String?]]?

      func managed(_ key: String) -> [String?] {
        recoverable?[key] ?? [applied[key] ?? nil, original[key] ?? nil]
      }
    }

    let simctl: Simctl
    let device: String
    /// The directory of installation records.
    let stateDirectory: URL

    var stateFile: URL { stateDirectory.appending(path: "\(device).json") }

    func install(runtime: URL, bundle: String) throws -> [String: Any] {
      let runtime = runtime.standardizedFileURL.resolvingSymlinksInPath()
      try RuntimePackage.validate(runtime)
      try FileManager.default.createDirectory(
        at: stateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let saved = try FileManager.default.fileExists(atPath: stateFile.path()) ? load() : nil
      let bundles: [String]
      let original: [String: String?]
      if let saved {
        guard saved.runtime == runtime.path(percentEncoded: false) else {
          throw CKSimError("Uninstall the existing runtime before selecting another release.")
        }
        bundles = Set(saved.bundles + [bundle]).sorted()
        original = saved.original
        for key in saved.applied.keys.sorted()
        where !saved.managed(key).contains(try simctl.environment(device, key)) {
          throw CKSimError("\(key) changed outside this installation; refusing to overwrite it.")
        }
      } else {
        bundles = [bundle]
        var values: [String: String?] = [:]
        for key in Self.keys { values[key] = try simctl.environment(device, key) }
        original = values
      }
      let loader = [
        original["DYLD_INSERT_LIBRARIES"] ?? nil,
        runtime.appending(path: "CKSimLoader.dylib").path(percentEncoded: false),
      ]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
      let values: [String: String] = [
        "DYLD_INSERT_LIBRARIES": loader,
        "CKSIM_RUNTIME": runtime.appending(path: "CKSimRuntime.dylib").path(percentEncoded: false),
        "CKSIM_BUNDLE_IDS": bundles.joined(separator: ","), "CKSIM_ENABLED": "1",
        "CKSIM_PROFILE": "ios-27.0",
      ]
      var recoverable: [String: [String?]] = [:]
      for key in Self.keys {
        var candidates: [String?] = [original[key] ?? nil, values[key]]
        if let saved { candidates += saved.managed(key) }
        var unique: [String?] = []
        for candidate in candidates where !unique.contains(candidate) { unique.append(candidate) }
        recoverable[key] = unique
      }
      var state = State(
        runtime: runtime.path(percentEncoded: false), bundles: bundles, original: original,
        applied: values.mapValues { $0 }, recoverable: recoverable)
      try save(state)
      for key in Self.keys { try simctl.setEnvironment(device, key, values[key]) }
      state.recoverable = nil
      try save(state)
      return ["installed": true, "simulator": device, "bundles": bundles, "profile": "ios-27.0"]
    }

    func uninstall() throws -> [String: Any] {
      let saved = try load()
      for key in saved.applied.keys.sorted()
      where !saved.managed(key).contains(try simctl.environment(device, key)) {
        throw CKSimError(
          "\(key) changed after installation; use repair to preserve unrelated loader entries.")
      }
      for key in Self.keys where saved.original.keys.contains(key) {
        try simctl.setEnvironment(device, key, saved.original[key] ?? nil)
      }
      try FileManager.default.removeItem(at: stateFile)
      return ["uninstalled": true, "simulator": device]
    }

    /// Restores the simulator's launchd environment after an interrupted or orphaned installation,
    /// removing only the recorded loader entry and keeping changes made by anything else.
    func repair() throws -> [String: Any] {
      guard FileManager.default.fileExists(atPath: stateFile.path()) else {
        return ["repaired": false, "simulator": device, "reason": "No saved installation."]
      }
      let path = stateFile.path(percentEncoded: false)
      guard let saved = try? load() else {
        throw CKSimError("Invalid ownership state in \(path); inspect this file before repair.")
      }
      for (field, values) in [("original", saved.original), ("applied", saved.applied)]
      where Set(values.keys) != Set(Self.keys) {
        throw CKSimError(
          "Invalid \(field) ownership values in \(path); inspect this file before repair.")
      }
      guard saved.runtime.hasPrefix("/") else {
        throw CKSimError(
          "Invalid runtime ownership path in \(path); inspect this file before repair.")
      }
      guard Set((saved.recoverable ?? [:]).keys).isSubset(of: Self.keys) else {
        throw CKSimError(
          "Invalid recoverable ownership values in \(path); inspect this file before repair.")
      }
      func ambiguous(_ key: String) -> CKSimError {
        CKSimError(
          "\(key) changed outside this installation; repair left the environment unchanged. "
            + "Inspect simulator key \(key) and \(path); preserve external edits, restore a saved "
            + "original/applied value deliberately, then retry repair.")
      }

      var current: [String: String?] = [:]
      for key in Self.keys { current[key] = try simctl.environment(device, key) }
      var target = saved.original
      // Check every key before the first write. Only the recorded loader entry belongs to this
      // installation; other injectors may append or remove their own entries.
      for key in Self.keys.dropFirst() where !saved.managed(key).contains(current[key] ?? nil) {
        throw ambiguous(key)
      }
      let key = "DYLD_INSERT_LIBRARIES"
      let loader = URL(filePath: saved.runtime).appending(path: "CKSimLoader.dylib").path(
        percentEncoded: false)
      let original = saved.original[key] ?? nil
      let expected = [original, loader].compactMap { $0 }.filter { !$0.isEmpty }.joined(
        separator: ":")
      guard saved.applied[key] == expected else {
        throw CKSimError("Invalid loader ownership in \(path); inspect this file before repair.")
      }
      let value = current[key] ?? nil
      var entries =
        value.map { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
        ?? []
      let originalCount =
        original.map {
          $0.split(separator: ":", omittingEmptySubsequences: false).count { $0 == loader }
        }
        ?? 0
      let count = entries.count { $0 == loader }
      if count > originalCount + 1 { throw ambiguous(key) }
      if count > originalCount {
        if let last = entries.lastIndex(of: loader) { entries.remove(at: last) }
        target[key] = .some(entries.joined(separator: ":"))
        if value == loader { target[key] = .some(original == "" ? "" : nil) }
      } else {
        target[key] = .some(value)
      }
      for key in Self.keys where (current[key] ?? nil) != (target[key] ?? nil) {
        try simctl.setEnvironment(device, key, target[key] ?? nil)
      }
      try FileManager.default.removeItem(at: stateFile)
      return ["repaired": true, "simulator": device]
    }

    private func load() throws -> State {
      try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
    }

    /// Writes the record atomically, readable only by its owner.
    private func save(_ state: State) throws {
      let temporary = stateDirectory.appending(path: ".install-\(UUID().uuidString)")
      let data = try JSONEncoder().encode(state)
      guard
        FileManager.default.createFile(
          atPath: temporary.path(), contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw CKSimError("Cannot write \(temporary.path(percentEncoded: false)).") }
      defer { try? FileManager.default.removeItem(at: temporary) }
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      guard rename(temporary.path(), stateFile.path()) == 0 else {
        throw CKSimError("Cannot write \(stateFile.path(percentEncoded: false)).")
      }
    }
  }
#endif
