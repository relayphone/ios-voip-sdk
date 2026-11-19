import Foundation
import Testing

@testable import MediaJourneyProtocol

struct VideoEvidenceTests {
  @Test func preparationCancellationHasAnAllowlistedCategory() {
    let failure = MediaJourneyFailure(CancellationError(), operation: .prepare)
    #expect(failure.operation == .prepare)
    #expect(failure.category == .cancelled)
  }

  @Test func videoControlsRequireOriginCurrentPhaseAndNoTerminalArming() throws {
    let helper = ProtocolTests()
    var session = try MediaJourneySession(
      fixture: .init(fixtureId: "fixture", conversationId: "call"))
    try session.accept(
      helper.command(
        session, .beginPhase, phase: "live", frequencies: Array(repeating: 650, count: 12)))
    for enabled in [true, true, false] {
      try session.accept(
        helper.command(session, .video, phase: "live", enabled: enabled, videoSource: .app))
    }
    for value in [
      helper.command(session, .video, phase: "old", enabled: true, videoSource: .app),
      helper.command(session, .video, phase: "live", enabled: true),
      helper.command(session, .video, phase: "live", enabled: true, videoSource: .server),
    ] {
      #expect(throws: MediaJourneySession.Failure.self) { try session.accept(value) }
    }
    try session.accept(helper.command(session, .armTeardown, phase: "live"))
    #expect(throws: MediaJourneySession.Failure.self) {
      try session.accept(
        helper.command(session, .video, phase: "live", enabled: true, videoSource: .app))
    }
  }

  @Test func serverRoomUpdateRequiresLiveScopeAndRejectsReplays() throws {
    let helper = ProtocolTests()
    var session = try MediaJourneySession(
      fixture: .init(fixtureId: "fixture", conversationId: "call"))
    let sessionId = session.id
    let id = UUID()
    func metadata(
      eventID: UUID = id, type: String = "video", session: UUID = sessionId,
      fixture: String = "fixture", conversation: String = "call", phase: String = "live",
      enabled: Bool = true
    ) -> String {
      """
      {"type":"\(type)","id":"\(eventID)","sessionId":"\(session)","fixtureId":"\(fixture)",
        "conversationId":"\(conversation)","phaseId":"\(phase)","enabled":\(enabled)}
      """
    }
    let early = metadata(eventID: UUID())
    #expect(session.acceptServerVideo(early) == nil)
    try session.accept(
      helper.command(
        session, .beginPhase, phase: "live", frequencies: Array(repeating: 650, count: 12)))
    for invalid in [
      "{}", metadata(type: "audio"), metadata(session: UUID()), metadata(fixture: "foreign"),
      metadata(conversation: "other"), metadata(eventID: UUID(), phase: "old"), early,
      metadata() + String(repeating: " ", count: 32_768),
    ] {
      #expect(session.acceptServerVideo(invalid) == nil)
    }
    #expect(session.acceptServerVideo(metadata())?.enabled == true)
    #expect(session.acceptServerVideo(metadata(enabled: false)) == nil)
    #expect(session.acceptServerVideo(metadata(eventID: UUID(), enabled: false))?.enabled == false)
    try session.accept(helper.command(session, .armTeardown, phase: "live"))
    #expect(session.acceptServerVideo(metadata(eventID: UUID())) == nil)
  }

  @Test func initialSnapshotIsSeparateFromConfirmedChangesAndSurvivesTerminalRemoval() throws {
    var history = MediaSDKVideoEvidence.History()
    history.record(.readySnapshot, hasVideo: true, connected: true, atMs: 100)
    history.record(.changed, hasVideo: false, connected: true, source: .server, atMs: 200)
    history.record(.ended, hasVideo: false, connected: false, atMs: 300)
    let evidence = MediaSDKVideoEvidence(
      clockID: UUID(), observedAtMs: 350, hasVideo: nil,
      onHold: nil, connected: false, events: history.events, overflow: history.overflow)
    let decoded = try JSONDecoder().decode(
      MediaSDKVideoEvidence.self, from: JSONEncoder().encode(evidence))
    #expect(decoded.hasVideo == nil)
    #expect(decoded.events.map(\.sequence) == [1, 2, 3])
    #expect(decoded.events.first?.kind == .readySnapshot)
    #expect(decoded.events.first?.source == nil)
    #expect(decoded.events[1].source == .server)
    #expect(decoded.events.last?.kind == .ended)
    #expect(decoded.events.last?.atMs == 300)
  }

  @Test func historyIsBoundedWithoutEvictingTheOriginalAnchor() {
    var history = MediaSDKVideoEvidence.History()
    history.record(.readySnapshot, hasVideo: true, connected: true, atMs: 0)
    for i in 1...300 {
      history.record(.changed, hasVideo: i % 2 == 0, connected: true, source: .app, atMs: Double(i))
    }
    #expect(history.events.count == 256)
    #expect(history.events.first?.kind == .readySnapshot)
    #expect(history.events.last?.sequence == 256)
    #expect(history.overflow)
  }

  @Test func fixtureInitialVideoIsOptionalAndNeverAnInventedChangeEvent() throws {
    for value in ["", ",\"initialVideo\":true", ",\"initialVideo\":false"] {
      let data = Data("{\"fixtureId\":\"fixture\",\"conversationId\":\"call\"\(value)}".utf8)
      let fixture = try JSONDecoder().decode(MediaJourneyFixture.self, from: data)
      #expect(fixture.initialVideo == (value.isEmpty ? nil : value.contains("true")))
    }
  }

  @Test func failureCodesNeverSerializeMessagesOrUnrecognizedDomains() throws {
    for domain in ["io.livekit.swift-sdk", NSURLErrorDomain, "token-secret"] {
      let error = NSError(
        domain: domain, code: 101, userInfo: [NSLocalizedDescriptionKey: "token-secret"])
      let failure = MediaJourneyFailure(error, operation: .prepare)
      let encoded = try JSONEncoder().encode(failure)
      let roundTrip = try JSONDecoder().decode(MediaJourneyFailure.self, from: encoded)
      #expect(roundTrip.code == 101)
      #expect(roundTrip.operation == .prepare)
      #expect(!String(decoding: encoded, as: UTF8.self).contains("token-secret"))
      #expect(
        roundTrip.category
          == (domain == "io.livekit.swift-sdk"
            ? .livekit : domain == NSURLErrorDomain ? .url : .other))
    }
  }

  @Test func wrappedNetworkFailuresRetainThreeSanitizedCauses() throws {
    let secret = "fixture-token-secret"
    let fourth = NSError(domain: NSCocoaErrorDomain, code: 4)
    let system = NSError(
      domain: NSPOSIXErrorDomain, code: 61, userInfo: [NSUnderlyingErrorKey: fourth])
    let url = NSError(
      domain: NSURLErrorDomain, code: -1004,
      userInfo: [
        NSUnderlyingErrorKey: system, NSURLErrorFailingURLErrorKey: URL(filePath: "/\(secret)"),
      ])
    let wrapper = NSError(domain: secret, code: 1, userInfo: [NSUnderlyingErrorKey: url])
    let error = NSError(
      domain: "io.livekit.swift-sdk", code: 202, userInfo: [NSUnderlyingErrorKey: wrapper])
    let encoded = try JSONEncoder().encode(MediaJourneyFailure(error, operation: .prepare))
    let failure = try JSONDecoder().decode(MediaJourneyFailure.self, from: encoded)
    #expect(failure.category == .livekit)
    #expect(failure.code == 202)
    #expect(failure.underlying?.map(\.category) == [.other, .url, .posix])
    #expect(failure.underlying?.map(\.code) == [1, -1004, 61])
    #expect(!String(decoding: encoded, as: UTF8.self).contains(secret))
  }
}
