/// A packet observation made independently of connection or audio activation.
///
/// The timestamp is when media observed evidence, not when the packet arrived. Missing events
/// mean unknown. Emit each direction at most once per preparation.
public struct MediaTransportEvent: Sendable, Equatable {
  /// The kind of transport observation.
  ///
  /// New kinds may be added. Compare the members your app understands and handle other
  /// values with a fallback, such as a `default` branch in a switch.
  public struct Kind: Hashable, Sendable {
    private let value: UInt8

    private init(_ value: UInt8) { self.value = value }

    /// An inbound RTP packet counter became greater than zero.
    public static let firstPacketReceived = Self(0)
    /// An outbound RTP packet counter became greater than zero.
    public static let firstPacketSent = Self(1)
  }
  /// The call whose transport carried the packet.
  public let callID: CallID
  /// The kind of transport observation.
  public let kind: Kind
  /// The suspending monotonic observation time in this process.
  public let observedAt: SuspendingClock.Instant

  /// Creates an observation backed by actual transport evidence.
  public init(callID: CallID, kind: Kind, observedAt: SuspendingClock.Instant) {
    self.callID = callID
    self.kind = kind
    self.observedAt = observedAt
  }
}
