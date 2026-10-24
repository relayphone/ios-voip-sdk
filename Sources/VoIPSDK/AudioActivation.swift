import Foundation

/// Genuine LCK callbacks grant audio authority; AV observations only revoke it.
enum AudioActivationEvent: Equatable { case activated, deactivated }

@MainActor
final class AudioActivationCoordinator {
  private var lckActive = false
  private(set) var isActive = false
  var onEvent: (@MainActor (AudioActivationEvent, Set<UUID>) -> Void)?

  func didActivate() {
    let changed = !isActive
    lckActive = true; isActive = true
    if changed { onEvent?(.activated, []) }
  }
  func didDeactivate() {
    let changed = lckActive
    lckActive = false; isActive = false
    if changed { onEvent?(.deactivated, []) }
  }
  func systemBecameInactive() { isActive = false }
  func reset() { lckActive = false; isActive = false }
}
