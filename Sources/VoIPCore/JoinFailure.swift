/// Why joining a call stopped before it took part on this device and returned to its preview.
public enum JoinFailure: Sendable, Hashable {
  /// The join was ended. The SDK now reports a local End through ``CallEvent/ended(_:)``.
  case ended
  /// The calling framework refused the request to join the call.
  case refused
  /// The calling framework reset while the call was joining.
  case frameworkReset
  /// Joining failed before the call took part, for example because placement, media preparation
  /// or audio session configuration failed, or a placement, preparation or action deadline passed.
  case failed(CallFailure)
}
