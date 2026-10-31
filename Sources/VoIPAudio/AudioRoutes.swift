public import Observation

/// The audio routes that calls can use, for the app's audio route picker.
///
/// Read ``available`` and ``current`` from SwiftUI or with Observation. They change as devices
/// connect and disconnect, as the system changes the route, and after
/// ``AudioSessionAdapter/selectRoute(_:)``.
///
/// The routes are the built-in receiver and speaker, and the wired, Bluetooth hands-free,
/// CarPlay and USB devices that have a microphone. A device that only plays audio, such as an
/// AirPlay device or a Bluetooth A2DP speaker, is a route while it's the current one: only the
/// system's route picker, `AVRoutePickerView`, selects it.
@MainActor
@Observable
public final class AudioRoutes {
  /// The routes that calls can use now: the built-in ones first, then the others in the system's
  /// order.
  public private(set) var available: [AudioRoute] = []

  /// The route that calls' audio uses now, or `nil` before the SDK starts.
  public private(set) var current: AudioRoute?

  @ObservationIgnored private var revision: UInt64 = 0

  nonisolated init() {}

  /// Applies the adapter's routes, unless a newer list was applied already.
  func apply(_ snapshot: RouteSnapshot) {
    guard snapshot.revision > revision else { return }
    revision = snapshot.revision
    if available != snapshot.routes { available = snapshot.routes }
    if current != snapshot.current { current = snapshot.current }
  }
}

/// The routes as the adapter last read them.
struct RouteSnapshot: Sendable {
  /// Increases with each snapshot, so that an older one is never applied.
  let revision: UInt64
  let routes: [AudioRoute]
  let current: AudioRoute?
}
