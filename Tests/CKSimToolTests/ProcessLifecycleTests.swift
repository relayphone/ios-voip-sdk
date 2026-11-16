#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import Darwin
  import Foundation
  import Synchronization
  import Testing

  @testable import CKSimTool

  struct ProcessLifecycleTests {
    let scratch: Scratch
    let identity: ProcessLifecycleIdentity
    let channel: URL

    init() throws {
      scratch = try Scratch()
      identity = try ProcessLifecycleIdentity(
        simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: "cold-run")
      channel = scratch.url.appending(path: "channel")
    }

    private func writer(_ id: UUID = UUID()) throws -> ProcessLifecycle {
      try ProcessLifecycle(channel: channel, identity: identity, producerID: id)
    }

    @Test func intentIsDurableWithoutARuntimeOrAPID() async throws {
      let producer = try writer()
      try await producer.record(.launchRequested, uptimeNanoseconds: 100, wallTimeMS: 900)
      let entries = try ProcessJournal(channel: channel, identity: identity).read()
      let row = try JSONDecoder().decode(
        ProcessLifecycleRecord.self, from: #require(entries.first).line)
      #expect(row.pid == nil && row.sequence == 1 && row.event == .launchRequested)
      #expect(row.runID == identity.runID && row.simulatorID == identity.simulatorID)
      #expect(!FileManager.default.fileExists(atPath: channel.appending(path: "session.json").path))
    }

    @Test func segmentsHaveIndependentSequencesAndStableMonotonicMerge() async throws {
      let first = try writer(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
      let second = try writer(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
      try await second.record(.dropped, uptimeNanoseconds: 200, wallTimeMS: 100)
      try await first.record(.launchRequested, uptimeNanoseconds: 100, wallTimeMS: 900)
      try await first.record(
        .exited, pid: 123, cause: .unknown, uptimeNanoseconds: 200, wallTimeMS: 50)
      let journal = ProcessJournal(channel: channel, identity: identity)
      let rows = try journal.read()
      #expect(rows.map(\.uptimeNanoseconds) == [100, 200, 200])
      #expect(rows.map(\.sequence) == [1, 2, 1])
      #expect(
        rows.map(\.producer) == [
          first.producerID.uuidString, first.producerID.uuidString, second.producerID.uuidString,
        ])
      #expect(try journal.read().map(\.line) == rows.map(\.line))
      #expect(throws: CKSimError.self) { try writer(first.producerID) }
    }

    @Test func invalidOrBackwardsObservationsDoNotConsumeASequence() async throws {
      let producer = try writer()
      try await producer.record(.launchRequested, uptimeNanoseconds: 100, wallTimeMS: 100)
      await #expect(throws: CKSimError.self) {
        try await producer.record(.exited, uptimeNanoseconds: 99)
      }
      await #expect(throws: ProcessLifecycleRecord.ValidationError.self) {
        try await producer.record(.exited, pid: 0, uptimeNanoseconds: 101)
      }
      try await producer.record(.exited, pid: 123, uptimeNanoseconds: 102)
      #expect(
        try ProcessJournal(channel: channel, identity: identity).read().map(\.sequence) == [1, 2])
    }

    @Test func runtimeAndHostUseAbsoluteTimeWithNoWallClockInference() async throws {
      let producer = try writer()
      try await producer.record(.launchRequested, uptimeNanoseconds: 100, wallTimeMS: 999)
      let directory = channel.appending(path: identity.runID)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let runtime = directory.appending(path: "events.jsonl")
      // Runtime source observations may arrive after a later observation was journaled.
      let rows =
        [
          #"{"schemaVersion":1,"sequence":1,"pid":12,"runID":"cold-run","bundleID":"dev.example.app","event":"runtime.installed","t_ms":0,"wallTimeMS":1,"uptimeNanoseconds":200}"#,
          #"{"schemaVersion":1,"sequence":2,"pid":12,"runID":"cold-run","bundleID":"dev.example.app","event":"sdk.connected","t_ms":0,"wallTimeMS":2,"uptimeNanoseconds":150}"#,
        ].joined(separator: "\n") + "\n"
      try Data(rows.utf8).write(to: runtime)
      let merged = try ProcessJournal(channel: channel, identity: identity).read()
      #expect(merged.map(\.uptimeNanoseconds) == [100, 150, 200])
      #expect(merged.map(\.sequence) == [1, 2, 1])
      try Data(
        rows.replacingOccurrences(of: #""uptimeNanoseconds":200"#, with: #""missing":200"#).utf8
      ).write(to: runtime)
      #expect(throws: CKSimError.self) {
        try ProcessJournal(channel: channel, identity: identity).read()
      }
    }

    @Test(arguments: ["sequence", "identity", "producer", "symlink", "partial", "alias"])
    func damagedSegmentsFailClosedOrWaitForAnIncompleteTail(kind: String) async throws {
      let producer = try writer(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
      try await producer.record(.launchRequested, uptimeNanoseconds: 100, wallTimeMS: 100)
      let file = producer.file
      let original = try String(contentsOf: file, encoding: .utf8)
      let changed: String
      switch kind {
      case "sequence":
        changed = original.replacingOccurrences(of: #""sequence":1"#, with: #""sequence":2"#)
      case "identity": changed = original.replacingOccurrences(of: "cold-run", with: "another-run")
      case "producer":
        changed = original.replacingOccurrences(
          of: producer.producerID.uuidString, with: UUID().uuidString)
      case "partial": changed = original + #"{"schemaVersion":1"#
      case "alias":
        let alias = file.deletingLastPathComponent().appending(
          path: file.lastPathComponent.lowercased())
        #expect(rename(file.path, alias.path) == 0)
        changed = original
      default:
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
          at: file, withDestinationURL: scratch.url.appending(path: "missing"))
        changed = original
      }
      if kind != "symlink" && kind != "alias" { try Data(changed.utf8).write(to: file) }
      let journal = ProcessJournal(channel: channel, identity: identity)
      if kind == "partial" {
        #expect(try journal.read().count == 1)
      } else {
        #expect(throws: (any Error).self) { try journal.read() }
      }
    }

    @Test func offlineEventsNeverContactTheAppOrRequireARuntimePackage() async throws {
      let producer = try writer()
      try await producer.record(.launchRequested)
      let simulator = FakeSimulator()
      let container = channel.deletingLastPathComponent().appending(path: "app")
      let documents = container.appending(path: "Documents")
      try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
      try FileManager.default.moveItem(
        at: channel, to: documents.appending(path: ".callkit-simulator"))
      simulator.state.withLock { $0.containers[bundle] = container }
      let printed = Mutex<[String]>([])
      var tool = Tool()
      tool.simctl = simulator.simctl
      tool.write = { line in printed.withLock { $0.append(line) } }
      try await Tool.$current.withValue(tool) {
        let command = try #require(
          CKSim.parseAsRoot([
            "events", "--simulator", device, "--bundle", bundle, "--run-id", identity.runID,
          ]) as? CKSim.Events)
        try await command.run()
      }
      #expect(printed.withLock { $0.count == 1 })
      #expect(simulator.calls == [["get_app_container", device, bundle, "data"]])
    }

    @Test func offlineEventsRejectMailboxReceiptsAndUnknownRuns() throws {
      #expect(throws: (any Error).self) {
        try CKSim.parseAsRoot([
          "events", "--run-id", "cold-run", "--command-receipt", "receipt.json",
        ])
      }
      #expect(throws: CKSimError.self) {
        try ProcessJournal(channel: channel, identity: identity).read()
      }
    }
  }
#endif
