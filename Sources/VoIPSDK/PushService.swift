// Public declarations that use Foundation types compile only on iOS and watchOS.
#if os(iOS) || os(watchOS)
public import Foundation
#else
import Foundation
#endif

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
public final class PushService {
  private let client: ConversationClient
  private nonisolated let intake: IncomingIntake
  private nonisolated let transport: IncomingReportTransport
  private let tokens = PushTokenStore()
  private(set) var owner: PushRegistryOwner?
  // The native process owner retains the proxy, which retains this service.
  // A weak cache preserves receiver identity across repeated start attempts.
  private weak var receiver: PushReceiverProxy?
  public var tokenState: PushTokenState { tokens.state }
  public var isStarted: Bool { owner?.isStarted ?? false }
  init(client: ConversationClient) {
    self.client = client
    intake = client.incomingIntake
    transport = client.incomingTransport
  }

  /// Registers the native receiver, preserving its identity across failed retries.
  public func start() throws(PushRegistrationError) {
    do {
      let receiver = receiver ?? PushReceiverProxy(service: self)
      let owner = try PushRegistryOwner.shared(receiver: receiver)
      self.receiver = receiver
      try owner.start()
      self.owner = owner
    } catch {
      let native = error as NSError
      guard native.domain == "VoIPSDK.PushRegistration" else {
        throw PushRegistrationError.systemFailure(domain: native.domain, code: native.code)
      }
      switch native.code {
      case 1: throw PushRegistrationError.wrongExecutor
      case 2: throw PushRegistrationError.invalidReceiver
      case 3: throw PushRegistrationError.receiverAlreadyRegistered
      case 4: throw PushRegistrationError.registryUnavailable
      default: throw PushRegistrationError.systemFailure(domain: native.domain, code: native.code)
      }
    }
  }
  @discardableResult
  public func observeToken(_ callback: @escaping @MainActor (PushTokenState) -> Void) -> UUID {
    tokens.observe(callback)
  }
  public func removeTokenObserver(_ token: UUID) { tokens.removeObserver(token) }
  func pushTokenDidUpdate(_ token: Data) { tokens.update(token) }
  func pushTokenDidInvalidate() { tokens.update(nil) }

  /// Remote-notification/Expo path for the unchanged FCM callEnded envelope.
  @discardableResult
  public func receiveRemoteMessage(_ dictionary: [AnyHashable: Any]) -> Bool {
    guard case .callEnded(let ended) = PushWire.parse(dictionary) else { return false }
    return client.receiveCallEnded(ended)
  }

  /// Reserve canonical metadata on PushKit's serial queue, before creating a
  /// Task. Reporting and native completion never depend on the SDK actor.
  nonisolated func receiveVoIPPush(_ payload: [AnyHashable: Any], mustReport: Bool,
                                 delivery: PushDelivery) {
    #if os(iOS) && targetEnvironment(simulator)
    let pushIdentifier = SimulatorSupport.currentPushIdentifier
    #endif
    let plan = IncomingPushPolicy.plan(PushWire.parse(payload), mustReport: mustReport)
    let reservation: IncomingIntake.Reservation
    do {
      switch plan {
      case .incoming(let incoming):
        reservation = try intake.reserve(incoming, source: .pushKit)
      case .fallback(let incoming, let ended):
        if let ended, intake.terminate(ended) { scheduleProjection() }
        reservation = try intake.reserve(incoming, source: .pushKit)
        intake.terminate(reservation.id, generation: reservation.generation, reason: .failed)
      case .callEnded(let ended):
        intake.terminate(ended)
        delivery.finish()
        scheduleProjection()
        return
      case .skip: delivery.finish(); return
      }
    } catch {
      NSLog("VoIPSDK: incoming push metadata reservation failed.")
      delivery.finish()
      return
    }
    guard case .report(let attempt) = reservation.disposition else {
      NSLog("VoIPSDK: required incoming report attempt was not reserved.")
      delivery.finish()
      return
    }
    let intake = intake, transport = transport
    Task.detached(priority: .userInitiated) {
      #if os(iOS) && targetEnvironment(simulator)
      let outcome = await SimulatorPushContext.$pushIdentifier.withValue(pushIdentifier) {
        await transport.report(reservation)
      }
      #else
      let outcome = await transport.report(reservation)
      #endif
      intake.complete(attempt, outcome: outcome)
      // The actual report has settled and shared metadata is committed. A
      // duplicate's public result may still await another real report; native
      // PushKit completion never waits for that normalization or for projection.
      delivery.finish()
      if case .failed = outcome { NSLog("VoIPSDK: incoming push reporting failed.") }
      self.scheduleProjection()
    }
  }

  private nonisolated func scheduleProjection() {
    Task { @MainActor [weak self] in self?.client.incomingIntakeDidChange() }
  }

}

@MainActor
private final class PushReceiverProxy: NSObject, PushReceiver {
  private let service: PushService

  init(service: PushService) {
    self.service = service
    super.init()
  }

  func pushTokenDidUpdate(_ token: Data) {
    service.pushTokenDidUpdate(token)
  }

  func pushTokenDidInvalidate() {
    service.pushTokenDidInvalidate()
  }

  nonisolated func receiveVoIPPush(_ payload: [AnyHashable: Any], mustReport: Bool,
                                 delivery: PushDelivery) {
    service.receiveVoIPPush(payload, mustReport: mustReport, delivery: delivery)
  }
}
#endif
