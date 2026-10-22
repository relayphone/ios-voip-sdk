#if canImport(AVFAudio) && (os(iOS) || os(watchOS))
import Foundation
import AVFAudio

@MainActor
final class SystemAudioSession {
  let routes = AudioRoutesStore()
  private var routeObserver: (any NSObjectProtocol)?

  init() {
    #if os(iOS)
    routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
      object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refreshRoutes() }
    }
    refreshRoutes()
    #endif
  }

  /// Creates and uses the framework object entirely on the worker. No framework object is sent
  /// across actors and no setActive call or synthetic activation is involved.
  static func configureForConversation() async throws {
    try await Task.detached {
      let session = AVAudioSession.sharedInstance()
      #if os(iOS)
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
      #else
      try session.setCategory(.playAndRecord, mode: .voiceChat)
      #endif
    }.value
  }

  func refreshRoutes() {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    func port(_ value: AVAudioSessionPortDescription) -> AudioRoutePort {
      AudioRoutePort(uid: value.uid, name: value.portName, type: value.portType.rawValue)
    }
    routes.update(inputs: (session.availableInputs ?? []).map(port),
      currentInputs: session.currentRoute.inputs.map(port), outputs: session.currentRoute.outputs.map(port))
    #endif
  }

  func selectRoute(_ id: String, isActive: Bool) throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    defer { refreshRoutes() }
    try routes.select(id, isActive: isActive) { selection in
      switch selection {
      case .speaker: try session.overrideOutputAudioPort(.speaker)
      case .input(let uid):
        guard let input = session.availableInputs?.first(where: { $0.uid == uid }) else {
          throw AudioRouteError.unknownRoute
        }
        try session.overrideOutputAudioPort(.none)
        try session.setPreferredInput(input)
      }
    }
    #else
    throw AudioRouteError.unsupported
    #endif
  }
}
#endif
