#if os(iOS)
  import AVFAudio
  import CallKit
  import Foundation
  import VoIPCore

  /// The provider's delegate, which passes on everything CallKit tells it to the adapter.
  ///
  /// The provider calls its delegate on `VoIPActor.queue`, so the delegate runs on `VoIPActor`
  /// and the adapter hears of the system's actions without hopping. The provider holds its
  /// delegate weakly, so the adapter keeps it, and the delegate holds the adapter weakly: an
  /// action that arrives once the adapter is gone fails.
  @VoIPActor
  final class ProviderDelegate: NSObject, @preconcurrency CXProviderDelegate {
    private weak var adapter: CallKitAdapter?

    init(adapter: CallKitAdapter) {
      self.adapter = adapter
    }

    private func perform(_ action: CXCallAction) {
      guard let adapter else { return action.fail() }
      adapter.perform(action)
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
      adapter?.reset()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
      perform(action)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
      perform(action)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
      perform(action)
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
      perform(action)
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
      perform(action)
    }

    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
      perform(action)
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
      perform(action)
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
      adapter?.timedOut(action)
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
      adapter?.send(.audioActivated)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
      adapter?.send(.audioDeactivated)
    }
  }
#endif
