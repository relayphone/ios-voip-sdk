import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct SDKDeviceQAConfiguration: Codable, Equatable {
  enum Scenario: String, Codable {
    case enrollment
    case lockedAnswer = "locked-answer"
    case activeCall = "active-call"
    case coldReporting = "cold-reporting"
  }
  let runID: UUID
  let scenario: Scenario
  init(runID: UUID, scenario: Scenario) { self.runID = runID; self.scenario = scenario }
}

final class SDKDeviceQAStorage {
  let configuration: SDKDeviceQAConfiguration
  let launchID: UUID
  let traceURL: URL
  let tokenURL: URL
  private let documentsURL: URL
  private let documents: Descriptor
  private let directory: Descriptor
  private let runDirectory: Descriptor
  private let trace: Descriptor
  private let traceName: String
  private let lock = NSLock()

  init(documentsURL: URL, configurationOverride: SDKDeviceQAConfiguration? = nil) throws {
    guard documentsURL.isFileURL else { throw StorageError.unsafePath }
    let documentsURL = documentsURL.standardizedFileURL
    let documents = try Self.openDirectory(at: documentsURL)
    let directory = try Self.privateDirectory(parent: documents, name: "SDKDeviceQA")
    let configuration: SDKDeviceQAConfiguration
    if let configurationOverride {
      configuration = configurationOverride
      try Self.atomicWrite(try JSONEncoder().encode(configuration), parent: directory, name: "config.json")
    } else if let data = try Self.readFile(parent: directory, name: "config.json") {
      configuration = try JSONDecoder().decode(SDKDeviceQAConfiguration.self, from: data)
    } else {
      configuration = SDKDeviceQAConfiguration(runID: UUID(), scenario: .enrollment)
      try Self.atomicWrite(try JSONEncoder().encode(configuration), parent: directory, name: "config.json")
    }
    try Self.validateFileIfPresent(parent: directory, name: "token.txt")
    let launchID = UUID()
    let traceName = launchID.uuidString + ".jsonl"
    let runDirectory = try Self.privateDirectory(parent: directory, name: configuration.runID.uuidString)
    let trace = try Self.createFile(parent: runDirectory, name: traceName, append: true)
    self.documentsURL = documentsURL
    self.documents = documents; self.directory = directory; self.runDirectory = runDirectory; self.trace = trace
    self.configuration = configuration; self.launchID = launchID; self.traceName = traceName
    let root = documentsURL.appendingPathComponent("SDKDeviceQA", isDirectory: true)
    traceURL = root.appendingPathComponent(configuration.runID.uuidString, isDirectory: true).appendingPathComponent(traceName)
    tokenURL = root.appendingPathComponent("token.txt")
  }

  /// Accept one UTF-8 JSON value. Embedded line separators would make a record
  /// ambiguous; an escaped JSON string newline remains valid ordinary bytes.
  func append(recordData: Data) throws {
    guard !recordData.isEmpty, String(data: recordData, encoding: .utf8) != nil,
          !recordData.contains(0x0a), !recordData.contains(0x0d) else { throw StorageError.invalidRecord }
    _ = try JSONSerialization.jsonObject(with: recordData, options: [.fragmentsAllowed])
    lock.lock(); defer { lock.unlock() }
    try validatePaths()
    try Self.validateName(parent: runDirectory, name: traceName, descriptor: trace, directory: false)
    var line = recordData; line.append(0x0a)
    try Self.write(line, to: trace)
    guard fsync(trace.value) == 0 else { throw StorageError.systemCall("sync trace", errno) }
  }

  func writeToken(_ value: String?) throws {
    lock.lock(); defer { lock.unlock() }
    try validatePaths()
    try Self.validateFileIfPresent(parent: directory, name: "token.txt")
    if let value {
      try Self.atomicWrite(Data(value.utf8), parent: directory, name: "token.txt")
    } else if unlinkat(directory.value, "token.txt", 0) != 0 && errno != ENOENT {
      throw StorageError.systemCall("remove token", errno)
    }
  }

  private func validatePaths() throws {
    var current = stat()
    guard lstat(documentsURL.path, &current) == 0 else { throw StorageError.unsafePath }
    try Self.validate(current, directory: true)
    try Self.sameFile(current, descriptor: documents)
    try Self.validateName(parent: documents, name: "SDKDeviceQA", descriptor: directory, directory: true)
    try Self.validateName(parent: directory, name: configuration.runID.uuidString, descriptor: runDirectory, directory: true)
  }

  private enum StorageError: Error {
    case unsafePath, invalidRecord
    case systemCall(String, Int32)
  }

  private final class Descriptor {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
  }

  private static func validate(_ metadata: stat, directory: Bool) throws {
    let expected = mode_t(directory ? S_IFDIR : S_IFREG)
    guard metadata.st_mode & mode_t(S_IFMT) == expected, metadata.st_uid == geteuid(),
          directory || metadata.st_nlink == 1 else { throw StorageError.unsafePath }
  }

  private static func metadata(parent: Descriptor, name: String) throws -> stat? {
    var value = stat()
    if fstatat(parent.value, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    guard errno == ENOENT else { throw StorageError.systemCall("inspect private path", errno) }
    return nil
  }

  private static func sameFile(_ metadata: stat, descriptor: Descriptor) throws {
    var opened = stat()
    guard fstat(descriptor.value, &opened) == 0,
          opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else { throw StorageError.unsafePath }
  }

  private static func validateName(parent: Descriptor, name: String, descriptor: Descriptor, directory: Bool) throws {
    guard let value = try metadata(parent: parent, name: name) else { throw StorageError.unsafePath }
    try validate(value, directory: directory)
    try sameFile(value, descriptor: descriptor)
  }

  private static func privatePermissions(_ descriptor: Descriptor, directory: Bool) throws {
    var value = stat()
    guard fstat(descriptor.value, &value) == 0 else { throw StorageError.systemCall("inspect private descriptor", errno) }
    try validate(value, directory: directory)
    guard fchmod(descriptor.value, directory ? 0o700 : 0o600) == 0 else {
      throw StorageError.systemCall("set private permissions", errno)
    }
    #if os(iOS)
    // Darwin protection class C is completeUntilFirstUserAuthentication. Using
    // the verified descriptor avoids following a path changed by another writer.
    // Class mapping: developer.apple.com/support/downloads/Apple-File-System-Reference.pdf, p. 143.
    guard fcntl(descriptor.value, F_SETPROTECTIONCLASS, 3) == 0 else {
      throw StorageError.systemCall("set file protection", errno)
    }
    #endif
  }

  private static func openDirectory(at url: URL) throws -> Descriptor {
    let value = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard value >= 0 else { throw StorageError.systemCall("open documents directory", errno) }
    let descriptor = Descriptor(value)
    var attributes = stat()
    guard fstat(value, &attributes) == 0 else { throw StorageError.systemCall("inspect documents directory", errno) }
    try validate(attributes, directory: true)
    return descriptor
  }

  private static func privateDirectory(parent: Descriptor, name: String) throws -> Descriptor {
    if mkdirat(parent.value, name, 0o700) != 0 && errno != EEXIST {
      throw StorageError.systemCall("create private directory", errno)
    }
    let value = openat(parent.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard value >= 0 else { throw StorageError.systemCall("open private directory", errno) }
    let descriptor = Descriptor(value)
    try privatePermissions(descriptor, directory: true)
    try validateName(parent: parent, name: name, descriptor: descriptor, directory: true)
    return descriptor
  }

  private static func validateFileIfPresent(parent: Descriptor, name: String) throws {
    guard let value = try metadata(parent: parent, name: name) else { return }
    try validate(value, directory: false)
    let opened = openat(parent.value, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard opened >= 0 else { throw StorageError.systemCall("open private file", errno) }
    let descriptor = Descriptor(opened)
    try sameFile(value, descriptor: descriptor)
    try privatePermissions(descriptor, directory: false)
    try validateName(parent: parent, name: name, descriptor: descriptor, directory: false)
  }

  private static func createFile(parent: Descriptor, name: String, append: Bool = false) throws -> Descriptor {
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | (append ? O_APPEND : 0)
    let value = openat(parent.value, name, flags, 0o600)
    guard value >= 0 else { throw StorageError.systemCall("create private file", errno) }
    let descriptor = Descriptor(value)
    try privatePermissions(descriptor, directory: false)
    return descriptor
  }

  private static func readFile(parent: Descriptor, name: String) throws -> Data? {
    try validateFileIfPresent(parent: parent, name: name)
    let value = openat(parent.value, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if value < 0 {
      guard errno == ENOENT else { throw StorageError.systemCall("open configuration", errno) }
      return nil
    }
    let descriptor = Descriptor(value)
    try privatePermissions(descriptor, directory: false)
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(value, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw StorageError.systemCall("read configuration", errno)
      }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= 65_536 else { throw StorageError.unsafePath }
    }
    try validateName(parent: parent, name: name, descriptor: descriptor, directory: false)
    return data
  }

  private static func write(_ data: Data, to descriptor: Descriptor) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        #if canImport(Darwin)
        let count = Darwin.write(descriptor.value, base.advanced(by: offset), bytes.count - offset)
        #else
        let count = Glibc.write(descriptor.value, base.advanced(by: offset), bytes.count - offset)
        #endif
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw StorageError.systemCall("write private file", errno) }
        offset += count
      }
    }
  }

  private static func atomicWrite(_ data: Data, parent: Descriptor, name: String) throws {
    try validateFileIfPresent(parent: parent, name: name)
    let temporary = "." + name + "." + UUID().uuidString + ".tmp"
    defer { _ = unlinkat(parent.value, temporary, 0) }
    let descriptor = try createFile(parent: parent, name: temporary)
    try write(data, to: descriptor)
    guard fsync(descriptor.value) == 0 else { throw StorageError.systemCall("sync private file", errno) }
    try validateFileIfPresent(parent: parent, name: name)
    guard renameat(parent.value, temporary, parent.value, name) == 0 else {
      throw StorageError.systemCall("replace private file", errno)
    }
    try validateName(parent: parent, name: name, descriptor: descriptor, directory: false)
  }
}
