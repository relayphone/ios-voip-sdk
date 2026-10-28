#if targetEnvironment(simulator)
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct ForegroundPhaseSession: Codable, Equatable {
  let schemaVersion: Int
  let bundleID: String
  let runID: String
  let pid: Int
  let profile: String
}

// Private acceptance instrumentation. A normal online Inspector receipt says
// nothing about UIKit activation; only this separate challenged receipt does.
@MainActor
final class ForegroundPhaseProbe: NSObject {
  private struct Identity: Codable, Equatable {
    let schemaVersion: Int
    let nonce: String
    let pid: Int32
    let bundleID: String
    let dataContainer: String
    let startedWallTimeMS: Int64
    let session: ForegroundPhaseSession
  }
  private struct Request: Decodable {
    let schemaVersion: Int
    let nonce: String
    let pid: Int32
    let bundleID: String
    let dataContainer: String
    let startedWallTimeMS: Int64
    let session: ForegroundPhaseSession
    let phase: String
    let challenge: String
    var identity: Identity {
      .init(schemaVersion: schemaVersion, nonce: nonce, pid: pid, bundleID: bundleID,
        dataContainer: dataContainer, startedWallTimeMS: startedWallTimeMS, session: session)
    }
  }
  private let nonce: String
  private let startedWallTimeMS: Int64
  private let documents: URL
  private let dataContainer: String
  private let bundleID: String
  private var identity: Identity?
  private var activeGeneration = 0
  private var lastDidBecomeActiveWallTimeMS: Int64?
  private var lastDidBecomeActiveUptimeNS: UInt64?

  init?(nonce: String, startedWallTimeMS: Int64) {
    guard !nonce.isEmpty, nonce.utf8.count <= 128,
          let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty,
          let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    do { try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true) }
    catch { return nil }
    guard let canonical = realpath(documents.path, nil) else { return nil }
    defer { free(canonical) }
    self.nonce = nonce
    self.startedWallTimeMS = startedWallTimeMS
    self.documents = documents
    self.dataContainer = (String(cString: canonical) as NSString).deletingLastPathComponent
    self.bundleID = bundleID
    super.init()
    #if canImport(UIKit)
    NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    #endif
  }

  #if canImport(UIKit)
  @objc private func didBecomeActive() {
    activeGeneration += 1
    lastDidBecomeActiveWallTimeMS = Int64(Date().timeIntervalSince1970 * 1000)
    lastDidBecomeActiveUptimeNS = DispatchTime.now().uptimeNanoseconds
  }
  func sample(session: ForegroundPhaseSession) {
    publish(session: session, active: UIApplication.shared.applicationState == .active)
  }
  #else
  // The host exercises the protocol core, never substitutes for UIKit proof.
  enum TestApplicationState { case active, inactive, background }
  func sample(session: ForegroundPhaseSession, applicationState: TestApplicationState) {
    publish(session: session, active: applicationState == .active)
  }
  #endif

  private func publish(session: ForegroundPhaseSession, active: Bool) {
    let current = Identity(schemaVersion: 1, nonce: nonce,
      pid: ProcessInfo.processInfo.processIdentifier, bundleID: bundleID,
      dataContainer: dataContainer, startedWallTimeMS: startedWallTimeMS, session: session)
    do {
      guard identity == nil || identity == current else { return }
      if identity == nil {
        try JSONEncoder().encode(current).write(
          to: documents.appendingPathComponent("cksim-foreground-phase-identity.json"), options: .atomic)
        identity = current
      }
      guard active else { return }
      let requestURL = documents.appendingPathComponent("cksim-foreground-phase-request.json")
      let data = try Data(contentsOf: requestURL, options: .mappedIfSafe)
      guard data.count <= 16_384 else { return }
      let request = try JSONDecoder().decode(Request.self, from: data)
      guard request.identity == current, UUID(uuidString: request.challenge) != nil,
            request.phase.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return }
      var acknowledgement = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
      acknowledgement["phase"] = request.phase
      acknowledgement["challenge"] = request.challenge
      acknowledgement["applicationState"] = "active"
      acknowledgement["publicationID"] = UUID().uuidString
      acknowledgement["wallTimeMS"] = Int64(Date().timeIntervalSince1970 * 1000)
      acknowledgement["uptimeNS"] = DispatchTime.now().uptimeNanoseconds
      acknowledgement["activeGeneration"] = activeGeneration
      acknowledgement["lastDidBecomeActiveWallTimeMS"] = lastDidBecomeActiveWallTimeMS
      acknowledgement["lastDidBecomeActiveUptimeNS"] = lastDidBecomeActiveUptimeNS
      try JSONSerialization.data(withJSONObject: acknowledgement, options: .sortedKeys).write(
        to: documents.appendingPathComponent("cksim-foreground-phase-ack.json"), options: .atomic)
    } catch {
      // A missing/malformed private request never changes app or acceptance state.
    }
  }
}
#endif
