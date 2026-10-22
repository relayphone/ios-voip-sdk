import Foundation

public struct PushToken: Codable, Sendable, Equatable {
  public let type: String
  public let value: String
  public init(value: String) { self.type = "apns-voip"; self.value = value }
}
public struct PushTokenState: Codable, Sendable, Equatable {
  public let revision: UInt64
  public let token: PushToken?
  private enum CodingKeys: String, CodingKey { case revision, token }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(revision, forKey: .revision)
    if let token { try container.encode(token, forKey: .token) }
    else { try container.encodeNil(forKey: .token) }
  }
}

/// Cached hydration and serialized updates, including invalidation before JS attaches.
@MainActor
final class PushTokenStore {
  private(set) var state = PushTokenState(revision: 0, token: nil)
  private var observers: [UUID: @MainActor (PushTokenState) -> Void] = [:]
  private var notifying = false
  @discardableResult func observe(_ callback: @escaping @MainActor (PushTokenState) -> Void) -> UUID {
    let token = UUID(); observers[token] = callback; callback(state); return token
  }
  func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
  func update(_ data: Data?) {
    let token = data.flatMap { value in
      value.isEmpty ? nil : PushToken(value: value.map { String(format: "%02x", $0) }.joined())
    }
    guard token != state.token else { return }
    state = PushTokenState(revision: state.revision &+ 1, token: token)
    guard !notifying else { return }
    notifying = true
    var update = state
    while true {
      for callback in Array(observers.values) { callback(update) }
      guard update.revision != state.revision else { break }
      update = state
    }
    notifying = false
  }
}

#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))
#if SWIFT_PACKAGE
import VoIPPlatform
#endif

/// Launch-owned process receiver. The Objective-C owner finishes each completion once.
@MainActor
public final class PushService: NSObject, PushReceiver {
  private let client: ConversationClient
  private let tokens = PushTokenStore()
  private var owner: PushRegistryOwner?
  public var tokenState: PushTokenState { tokens.state }
  public var isStarted: Bool { owner?.isStarted ?? false }
  init(client: ConversationClient) { self.client = client; super.init() }

  public func start() throws {
    let owner = try PushRegistryOwner.shared(receiver: self)
    try owner.start()
    self.owner = owner
  }
  @discardableResult
  public func observeToken(_ callback: @escaping @MainActor (PushTokenState) -> Void) -> UUID {
    tokens.observe(callback)
  }
  public func removeTokenObserver(_ token: UUID) { tokens.removeObserver(token) }
  public func pushTokenDidUpdate(_ token: Data) { tokens.update(token) }
  public func pushTokenDidInvalidate() { tokens.update(nil) }

  /// Remote-notification/Expo path for the unchanged FCM callEnded envelope.
  @discardableResult
  public func receiveRemoteMessage(_ dictionary: [AnyHashable: Any]) -> Bool {
    guard case .callEnded(let ended) = PushWire.parse(dictionary) else { return false }
    return client.receiveCallEnded(ended)
  }

  public func receiveVoIPPush(_ payload: [AnyHashable: Any], mustReport: Bool,
                             completion: @escaping () -> Void) {
    let plan = IncomingPushPolicy.plan(PushWire.parse(payload), mustReport: mustReport)
    // Never capture the untyped dictionary in a Task. All decision inputs are values.
    switch plan {
    case .skip: completion()
    case .callEnded(let ended): client.receiveCallEnded(ended); completion()
    case .incoming, .fallback:
      Task { @MainActor in
        defer { completion() }
        switch plan {
        case .incoming(let incoming):
          do { _ = try await self.client.reportIncomingConversation(incoming, source: .pushKit) }
          catch { NSLog("VoIPSDK: incoming push reporting failed.") }
        case .fallback(let incoming, let ended):
          if let ended { self.client.receiveCallEnded(ended) }
          do {
            let id = try await self.client.reportIncomingConversation(incoming, source: .pushKit)
            try self.client.reportConversation(id, report: .ended(.failed))
          } catch { NSLog("VoIPSDK: required fallback push reporting failed.") }
        default: break
        }
      }
    }
  }
}
#endif
