#if canImport(AVFAudio) && (os(iOS) || os(watchOS))
import Foundation
import AVFAudio
import os
#if canImport(VoIPPlatform)
import VoIPPlatform
#endif


enum SystemAudioLifecycleEvent: Sendable, Equatable {
  case active
  case inactive(source: Int?, interruptionReason: UInt?)
  case resumptionRecommended(Bool)
  case mediaServicesReset
}

private struct ObservedAudioRoutes: Sendable {
  let inputs: [AudioRoutePort]
  let currentInputs: [AudioRoutePort]
  let outputs: [AudioRoutePort]
}

@MainActor
final class SystemAudioSession {
  let routes = AudioRoutesStore()
  var onLifecycle: (@MainActor (SystemAudioLifecycleEvent) -> Void)?
  private var observers: [any NSObjectProtocol] = []
  private var lifecycleObserver: VSAudioSessionLifecycleObserver?
  private var probeTask: Task<Void, Never>?
  private var probeGeneration: UInt64 = 0
  private let authorization = OSAllocatedUnfairLock(initialState: false)

  init() {
    #if os(iOS)
    observe(AVAudioSession.routeChangeNotification) { _, owner in owner.refreshRoutes() }
    #endif
    lifecycleObserver = VSAudioSessionLifecycleObserver { [weak self] value in
      let event: SystemAudioLifecycleEvent
      switch value.kind {
      case .active: event = .active
      case .inactive:
        event = .inactive(source: value.hasSource ? value.source : nil,
          interruptionReason: value.hasInterruptionReason ? value.interruptionReason : nil)
      case .resumptionRecommended: event = .resumptionRecommended(value.shouldResume)
      case .mediaServicesReset: event = .mediaServicesReset
      @unknown default: return
      }
      MainActor.assumeIsolated { self?.deliver(event) }
    }
    refreshRoutes()
  }

  /// Resumption is advisory: it never activates a session or authorizes an engine.
  private func deliver(_ event: SystemAudioLifecycleEvent) {
    switch event {
    case .inactive, .mediaServicesReset: authorization.withLock { $0 = false }
    case .active, .resumptionRecommended: break
    }
    onLifecycle?(event)
    refreshRoutes()
  }

  private func observe(_ name: Notification.Name,
                       receive: @escaping @MainActor (Notification, SystemAudioSession) -> Void) {
    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
      // The observer is explicitly delivered on main; decode context values only.
      MainActor.assumeIsolated {
        guard let self else { return }
        receive(notification, self)
      }
    })
  }

  func setSystemAudioAuthorization(_ active: Bool) { authorization.withLock { $0 = active } }

  static func configureForConversation() async throws {
    try await AudioSessionQueue.shared.configureForConversation()
  }


  func refreshRoutes() {
    probeGeneration &+= 1
    let generation = probeGeneration
    probeTask?.cancel()
    probeTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      let observation = await AudioSessionQueue.shared.observeRoutes()
      guard let self, self.probeGeneration == generation, !Task.isCancelled else { return }
      self.publish(observation)
      self.probeTask = nil
    }
  }

  private func publish(_ observation: ObservedAudioRoutes) {
    routes.update(inputs: observation.inputs, currentInputs: observation.currentInputs, outputs: observation.outputs)
  }

  private func refreshAfterCommand() async {
    probeGeneration &+= 1
    let generation = probeGeneration
    probeTask?.cancel(); probeTask = nil
    let observation = await AudioSessionQueue.shared.observeRoutes()
    guard probeGeneration == generation else { return }
    publish(observation)
  }

  func selectRoute(_ id: String, isActive: Bool) async throws {
    let selection = try routes.selection(id, isActive: isActive)
    guard let selection else { return }
    do {
      try await AudioSessionQueue.shared.selectRoute(selection, authorization: authorization)
      await refreshAfterCommand()
    } catch {
      await refreshAfterCommand()
      throw error
    }
  }
}

private extension AudioSessionQueue {
  func observeRoutes() -> ObservedAudioRoutes {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    func port(_ value: AVAudioSessionPortDescription) -> AudioRoutePort {
      AudioRoutePort(uid: value.uid, name: value.portName, type: value.portType.rawValue)
    }
    let current = session.currentRoute
    return ObservedAudioRoutes(inputs: (session.availableInputs ?? []).map(port),
      currentInputs: current.inputs.map(port), outputs: current.outputs.map(port))
    #else
    return ObservedAudioRoutes(inputs: [], currentInputs: [], outputs: [])
    #endif
  }

  func selectRoute(_ selection: AudioRouteSelection, authorization: OSAllocatedUnfairLock<Bool>) throws {
    #if os(iOS)
    guard authorization.withLock({ $0 }) else { throw AudioRouteError.audioSessionInactive }
    let session = AVAudioSession.sharedInstance()
    switch selection {
    case .speaker: try session.overrideOutputAudioPort(.speaker)
    case .input(let uid):
      guard let input = session.availableInputs?.first(where: { $0.uid == uid }) else { throw AudioRouteError.unknownRoute }
      try session.overrideOutputAudioPort(.none)
      guard authorization.withLock({ $0 }) else { throw AudioRouteError.audioSessionInactive }
      try session.setPreferredInput(input)
    }
    #else
    throw AudioRouteError.unsupported
    #endif
  }
}
#endif
