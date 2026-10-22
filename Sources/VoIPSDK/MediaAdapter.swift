#if canImport(AVFAudio) && (os(iOS) || os(watchOS))
import AVFAudio

/// Native backend operations follow genuine LCK callbacks; they never activate the system session.
/// Implementations must enqueue potentially blocking engine work away from MainActor, preserve
/// operation order, and return errors. Backend completion does not prove activation or media flow.
@MainActor
public protocol MediaAdapter: AnyObject {
  /// Nonblocking value update from the real system state. Workers must suppress queued enables
  /// when this is false; do not perform engine work or synthesize callbacks in this method.
  func setSystemAudioAuthorization(_ active: Bool)
  /// Idempotently establish external session ownership and gate media until activation.
  func prepare() async throws
  func didActivate(_ audioSession: AVAudioSession) async throws
  func didDeactivate(_ audioSession: AVAudioSession) async throws
}

/// Select explicitly when the application owns its media integration.
@MainActor
public final class NoMediaAdapter: MediaAdapter {
  public init() {}
  public func setSystemAudioAuthorization(_ active: Bool) {}
  public func prepare() async throws {}
  public func didActivate(_ audioSession: AVAudioSession) async throws {}
  public func didDeactivate(_ audioSession: AVAudioSession) async throws {}
}
#endif
