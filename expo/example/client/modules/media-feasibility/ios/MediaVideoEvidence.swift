#if DEBUG
  import Foundation

  /// SDK observations on the existing native clock, independent of command completion.
  struct MediaSDKVideoEvidence: Codable {
    enum Source: String, Codable { case app, server }
    enum Kind: String, Codable { case readySnapshot, changed, held, resumed, ended }
    struct Event: Codable {
      let sequence: Int
      let kind: Kind
      let hasVideo: Bool
      let connected: Bool
      let source: Source?
      let atMs: Double
    }
    struct History {
      private(set) var events: [Event] = []
      private(set) var overflow = false
      mutating func record(
        _ kind: Kind, hasVideo: Bool, connected: Bool, source: Source? = nil, atMs: Double
      ) {
        guard events.count < 256 else {
          overflow = true
          return
        }
        events.append(
          Event(
            sequence: events.count + 1, kind: kind, hasVideo: hasVideo, connected: connected,
            source: source, atMs: atMs))
      }
    }
    let clockID: UUID
    let observedAtMs: Double
    let hasVideo: Bool?
    let onHold: Bool?
    let connected: Bool
    let events: [Event]
    let overflow: Bool
  }

  /// No descriptions, raw domains, URLs or userInfo cross the fixture boundary.
  struct MediaJourneyFailure: Codable {
    enum Operation: String, Codable { case prepare, connect, video, command }
    enum Category: String, Codable { case cancelled, livekit, url, osStatus, posix, cocoa, other }
    let operation: Operation
    let category: Category
    let code: Int
    init(_ error: any Error, operation: Operation) {
      self.operation = operation
      let native = error as NSError
      code = native.code
      switch native.domain {
      case _ where error is CancellationError: category = .cancelled
      case "io.livekit.swift-sdk": category = .livekit
      case NSURLErrorDomain: category = .url
      case NSOSStatusErrorDomain: category = .osStatus
      case NSPOSIXErrorDomain: category = .posix
      case NSCocoaErrorDomain: category = .cocoa
      default: category = .other
      }
    }
  }
#endif
