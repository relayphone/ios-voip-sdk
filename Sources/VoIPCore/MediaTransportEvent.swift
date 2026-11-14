/// A packet observation made independently of connection or audio activation.
///
/// The timestamp is when media observed evidence, not when the packet arrived. Missing events
/// mean unknown. Emit each direction at most once per preparation.
public struct MediaTransportEvent: Sendable, Equatable {
  /// The first packet direction that the transport could observe.
  public enum Kind: Sendable {
    /// An inbound RTP packet counter became greater than zero.
    case firstPacketReceived
    /// An outbound RTP packet counter became greater than zero.
    case firstPacketSent
  }
  /// The call whose transport carried the packet.
  public let callID: CallID
  /// The observed direction.
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
