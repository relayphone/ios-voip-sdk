import Foundation

public struct AudioRoute: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  /// AVAudioSession port type raw value, including Speaker for the speaker override.
  public let type: String
  public init(id: String, name: String, type: String) { self.id = id; self.name = name; self.type = type }
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
enum AudioRouteSelection: Equatable { case speaker, input(String) }

/// Projects only observed inputs/current output. It never invents other output devices.
@MainActor
final class AudioRoutesStore {
  static let speakerID = "speaker"
  private var selections: [String: AudioRouteSelection] = [:]
  private var observers: [UUID: @MainActor (AudioRoutesSnapshot) -> Void] = [:]
  private var publishing = false
  private(set) var snapshot = AudioRoutesSnapshot(revision: 0, routes: [], current: nil)

  @discardableResult
  func observe(_ callback: @escaping @MainActor (AudioRoutesSnapshot) -> Void) -> UUID {
    let id = UUID(); observers[id] = callback; callback(snapshot); return id
  }
  func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

  func update(inputs: [AudioRoutePort], currentInputs: [AudioRoutePort], outputs: [AudioRoutePort]) {
    let speaker = AudioRoute(id: Self.speakerID, name: "Speaker", type: "Speaker")
    var routes: [AudioRoute] = []
    var available: [String: AudioRouteSelection] = [:]
    for input in inputs {
      let id = "input:" + input.uid
      guard available[id] == nil else { continue }
      routes.append(AudioRoute(id: id, name: input.name, type: input.type))
      available[id] = .input(input.uid)
    }
    routes.append(speaker); available[speaker.id] = .speaker
    var current: AudioRoute?
    if let output = outputs.first {
      if output.type == "Speaker" { current = speaker }
      else if let input = currentInputs.first(where: { input in
        input.type == output.type ||
          (input.type == "MicrophoneBuiltIn" && output.type == "Receiver") ||
          (input.type == "MicrophoneWired" && output.type == "Headphones")
      }), let route = routes.first(where: { $0.id == "input:" + input.uid }) { current = route }
      else {
        let route = AudioRoute(id: "output:" + output.uid, name: output.name, type: output.type)
        current = route
        // An observed output may lack a selectable input (for example AirPlay).
        routes.append(route)
      }
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

  func select(_ id: String, isActive: Bool, apply: (AudioRouteSelection) throws -> Void) throws {
    guard isActive else { throw AudioRouteError.audioSessionInactive }
    guard let selection = selections[id] else {
      // The already-current output needs no unavailable arbitrary-output API.
      if snapshot.current?.id == id { return }
      throw AudioRouteError.unknownRoute
    }
    try apply(selection)
  }
}
