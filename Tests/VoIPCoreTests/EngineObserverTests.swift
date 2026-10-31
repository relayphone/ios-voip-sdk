import Testing
import VoIPTesting

@testable import VoIPCore

extension EngineTests {
  /// Observers, which follow the client's calls from the moment it starts.
  @Suite("Observers")
  @MainActor
  struct Observers {
    /// The VoIP push that cold-launched the app arrives as soon as the SDK attaches the push
    /// source, which can be before the app's own code runs again.
    @Test func observerSeesTheFirstEventOfAColdLaunch() async throws {
      let observer = Recorder()
      let h = try Harness(
        subscribe: false, pending: [.incoming(ringingCall, eventID: e1)], observers: [observer])
      // The SDK attaches and reports the push's call while the app finishes launching.
      await onVoIPActor {}

      _ = await h.client.report(incoming(otherCallID, .preview))
      let first = try await observer.next()
      #expect(first == .presented(callID))
      #expect(try await observer.next() == .previewStarted(otherCallID, .policy))
    }

    /// A stream from `events()` starts when the app subscribes, so it misses what happened
    /// before; `calls` still holds the call.
    @Test func streamCreatedAfterStartMissesTheFirstEventOfAColdLaunch() async throws {
      let h = try Harness(subscribe: false, pending: [.incoming(ringingCall, eventID: e1)])
      await onVoIPActor {}
      h.subscribe()

      _ = await h.client.report(incoming(otherCallID, .preview))
      #expect(try await h.next() == .previewStarted(otherCallID, .policy))
      await h.until { $0.calls.map(\.id) == [callID, otherCallID] }
    }

    @Test func attachesEachObserverOnceInOrderBeforeStartReturns() throws {
      let log = AttachmentLog()
      let first = Recorder(name: "first", log: log)
      let second = Recorder(name: "second", log: log)
      let h = try Harness(observers: [first, second])
      #expect(log.names == ["first", "second"])
      #expect(first.client === h.client)
      #expect(second.client === h.client)
    }

    @Test func keepsItsObserversForItsLife() throws {
      var observer: Recorder? = Recorder()
      weak let attached = observer
      var h: Harness? = try Harness(observers: [try #require(observer)])
      observer = nil
      #expect(attached != nil)
      #expect(h != nil)
      h = nil
      #expect(attached == nil)
    }

    @Test func clientThatDoesNotStartAttachesNoObserver() throws {
      let running = try Harness()
      let observer = Recorder()
      #expect(throws: StartupError.alreadyStarted) {
        _ = try VoIPClient.start(
          framework: FakeCallingFramework(), media: FakeMedia(), observers: [observer])
      }
      #expect(observer.client == nil)
      withExtendedLifetime(running) {}
    }
  }
}

/// The names of observers, in the order the client attached them.
@MainActor
final class AttachmentLog {
  private(set) var names: [String] = []

  func append(_ name: String) {
    names.append(name)
  }
}

/// An observer that subscribes to events when the client attaches it, and reads them when the
/// test asks.
@MainActor
final class Recorder: CallObserver {
  private let name: String
  private let log: AttachmentLog?
  private(set) weak var client: VoIPClient?
  private var iterator: AsyncStream<CallEvent>.Iterator?

  init(name: String = "recorder", log: AttachmentLog? = nil) {
    self.name = name
    self.log = log
  }

  func attach(to client: VoIPClient) {
    #expect(self.client == nil, "The client attaches an observer once")
    self.client = client
    iterator = client.events().makeAsyncIterator()
    log?.append(name)
  }

  /// The next event.
  func next() async throws -> Seen {
    var iterator = try #require(iterator, "The client attached the observer")
    let event = await iterator.next(isolation: #isolation)
    self.iterator = iterator
    return Seen(try #require(event, "The event stream doesn't finish"))
  }
}
