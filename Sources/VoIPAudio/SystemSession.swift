#if os(iOS)
  import AVFAudio
  import Dispatch
  import Foundation
  #if SWIFT_PACKAGE
    import VoIPCore
  #endif

  /// The app's `AVAudioSession`.
  @VoIPActor
  final class SystemSession: SessionControl {
    private let session = AVAudioSession.sharedInstance()

    nonisolated init() {}

    func setCategory(options: CategoryOptions) throws(AudioSessionError) {
      do {
        try session.setCategory(
          .playAndRecord, mode: .voiceChat, options: AVAudioSession.CategoryOptions(options))
      } catch {
        throw .configurationFailed
      }
    }

    func ports() -> SessionPorts {
      SessionPorts(
        inputs: (session.availableInputs ?? []).map(Port.init),
        outputs: session.currentRoute.outputs.map(Port.init))
    }

    func overrideOutput(toSpeaker: Bool) throws(AudioRouteError) {
      do {
        try session.overrideOutputAudioPort(toSpeaker ? .speaker : .none)
      } catch {
        throw .refused
      }
    }

    func setPreferredInput(uid: String) throws(AudioRouteError) {
      guard let input = session.availableInputs?.first(where: { $0.uid == uid }) else {
        throw .unavailable
      }
      do {
        try session.setPreferredInput(input)
      } catch {
        throw .refused
      }
    }
  }

  /// The audio session's notifications from the default notification center.
  ///
  /// The session posts them on its own threads. Each is read where it's posted, then delivered on
  /// `VoIPActor.queue` in the order it was posted.
  @VoIPActor
  final class SystemNotifications: SessionNotifications {
    private var observers: [any NSObjectProtocol] = []

    nonisolated init() {}

    isolated deinit {
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start(_ receive: @escaping @VoIPActor (SessionNotification) -> Void) {
      guard observers.isEmpty else { return }
      func observe(
        _ name: Notification.Name,
        _ read: @escaping @Sendable (Notification) -> SessionNotification?
      ) {
        let observer = NotificationCenter.default.addObserver(
          forName: name, object: nil, queue: nil
        ) { note in
          guard let notification = read(note) else { return }
          VoIPActor.queue.async { VoIPActor.assumeIsolated { receive(notification) } }
        }
        observers.append(observer)
      }
      if #available(iOS 27, *) {
        observe(AVAudioSession.didBecomeInactiveNotification) { note in
          let context =
            note.userInfo?[AVAudioSession.deactivationContextKey]
            as? AVAudioSession.DeactivationContext
          let reason = context?.interruptionContext?.reason
          return .becameInactive(interruption: reason.map(AudioInterruptionReason.init))
        }
        observe(AVAudioSession.resumptionRecommendationNotification) { _ in
          .resumptionRecommended
        }
      } else {
        observe(AVAudioSession.interruptionNotification, Self.interruption)
      }
      observe(AVAudioSession.mediaServicesWereResetNotification) { _ in .mediaServicesWereReset }
      observe(AVAudioSession.routeChangeNotification) { _ in .routesChanged }
      observe(AVAudioSession.availableInputsChangeNotification) { _ in .routesChanged }
    }

    /// Reads `AVAudioSession.interruptionNotification`, which systems before iOS 27 post.
    private nonisolated static func interruption(_ note: Notification) -> SessionNotification? {
      guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return nil }
      switch type {
      case .began:
        let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
          .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
        return .interruptionBegan(reason.map(AudioInterruptionReason.init))
      case .ended:
        return .interruptionEnded
      @unknown default:
        return nil
      }
    }
  }

  extension AudioInterruptionReason {
    init(_ reason: AVAudioSession.InterruptionReason) {
      self =
        switch reason {
        case .builtInMicMuted: .builtInMicMuted
        case .routeDisconnected: .routeDisconnected
        default: .otherAudio
        }
    }
  }

  extension AVAudioSession.CategoryOptions {
    init(_ options: CategoryOptions) {
      self = []
      if options.contains(.allowBluetoothHFP) { insert(.allowBluetoothHFP) }
      if options.contains(.allowBluetoothA2DP) { insert(.allowBluetoothA2DP) }
      if options.contains(.allowAirPlay) { insert(.allowAirPlay) }
      if options.contains(.defaultToSpeaker) { insert(.defaultToSpeaker) }
    }
  }

  extension Port {
    init(_ port: AVAudioSessionPortDescription) {
      self.init(uid: port.uid, name: port.portName, type: PortType(port.portType))
    }
  }

  extension Port.PortType {
    init(_ port: AVAudioSession.Port) {
      self =
        switch port {
        case .builtInMic: .builtInMic
        case .builtInReceiver: .builtInReceiver
        case .builtInSpeaker: .builtInSpeaker
        case .headphones: .headphones
        case .headsetMic: .headsetMic
        case .bluetoothHFP: .bluetoothHFP
        case .bluetoothA2DP: .bluetoothA2DP
        case .bluetoothLE: .bluetoothLE
        case .airPlay: .airPlay
        case .carAudio: .carAudio
        case .usbAudio: .usbAudio
        default: .other
        }
    }
  }
#endif
