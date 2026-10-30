import Foundation

/// An observed audio route or an explicit speaker override target.
public struct AudioRoute: Codable, Sendable, Equatable, Identifiable {
  /// An opaque route identity, distinct from conversation and observer identifiers.
  public struct ID: RawRepresentable, Codable, Sendable, Hashable {
    /// The route identity used in Codable and JavaScript payloads.
    public let rawValue: String

    /// Restores an identity received from a route snapshot or a serialized payload.
    /// Selection still requires the route to be available and audio to be active.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Decodes the existing string representation of a route identity.
    public init(from decoder: any Decoder) throws {
      rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the identity as a string, preserving the existing wire format.
    public func encode(to encoder: any Encoder) throws {
      var value = encoder.singleValueContainer()
      try value.encode(rawValue)
    }
  }

  /// The typed identity to pass to route selection.
  public let id: ID
  public let name: String
  /// Raw OS port type; the explicit speaker override target uses Speaker.
  public let type: String
  /// Creates a route description with a typed identity.
  public init(id: ID, name: String, type: String) { self.id = id; self.name = name; self.type = type }
}

public struct AudioRoutesSnapshot: Codable, Sendable, Equatable {
  public let revision: UInt64
  public let routes: [AudioRoute]
  public let current: AudioRoute?
  public init(revision: UInt64, routes: [AudioRoute], current: AudioRoute?) {
    self.revision = revision; self.routes = routes; self.current = current
  }
  private enum CodingKeys: String, CodingKey { case revision, routes, current }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(revision, forKey: .revision); try values.encode(routes, forKey: .routes)
    if let current { try values.encode(current, forKey: .current) }
    else { try values.encodeNil(forKey: .current) }
  }
}

public enum AudioRouteError: Error, Sendable, Equatable {
  case audioSessionInactive, unknownRoute, unsupported
}

struct AudioRoutePort: Sendable, Equatable {
  let uid: String
  let name: String
  let type: String
}
enum AudioRouteSelection: Sendable, Equatable { case speaker, input(String), currentOutput(String) }

/// Projects only observed inputs/current output. It never invents other output devices.
@MainActor
final class AudioRoutesStore {
  static let speakerID = AudioRoute.ID(rawValue: "speaker")
  private var selections: [AudioRoute.ID: AudioRouteSelection] = [:]
  private var observers: [UUID: @MainActor (AudioRoutesSnapshot) -> Void] = [:]
  private var publishing = false
  private(set) var snapshot = AudioRoutesSnapshot(revision: 0, routes: [], current: nil)

  @discardableResult
  func observe(_ callback: @escaping @MainActor (AudioRoutesSnapshot) -> Void) -> UUID {
    let id = UUID(); observers[id] = callback; callback(snapshot); return id
  }
  func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

  func update(inputs: [AudioRoutePort], outputs: [AudioRoutePort]) {
    let speaker = AudioRoute(id: Self.speakerID, name: "Speaker", type: "Speaker")
    var routes: [AudioRoute] = []
    var available: [AudioRoute.ID: AudioRouteSelection] = [:]
    for input in inputs {
      let id = AudioRoute.ID(rawValue: "input:" + input.uid)
      guard available[id] == nil else { continue }
      routes.append(AudioRoute(id: id, name: input.name, type: input.type))
      available[id] = .input(input.uid)
    }
    routes.append(speaker); available[speaker.id] = .speaker
    let current = outputs.first.map { AudioRoute(id: .init(rawValue: "output:" + $0.uid), name: $0.name, type: $0.type) }
    // Current is the observed output itself, never a paired input or a command
    // target. An OS observation does not imply arbitrary output selection exists.
    if let current, let output = outputs.first {
      routes.append(current); available[current.id] = .currentOutput(output.uid)
    }
    selections = available
    guard routes != snapshot.routes || current != snapshot.current else { return }
    snapshot = AudioRoutesSnapshot(revision: snapshot.revision &+ 1, routes: routes, current: current)
    guard !publishing else { return }
    publishing = true
    var value = snapshot
    while true {
      for callback in Array(observers.values) { callback(value) }
      guard value.revision != snapshot.revision else { break }
      value = snapshot
    }
    publishing = false
  }

  func selection(_ id: AudioRoute.ID, isActive: Bool) throws -> AudioRouteSelection {
    guard isActive else { throw AudioRouteError.audioSessionInactive }
    guard let selection = selections[id] else { throw AudioRouteError.unknownRoute }
    return selection
  }
}
