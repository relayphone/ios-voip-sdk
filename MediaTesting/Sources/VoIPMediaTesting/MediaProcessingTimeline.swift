#if DEBUG && os(iOS) && targetEnvironment(simulator)
  #if SWIFT_PACKAGE
    import LiveKit
  #else
    import LiveKitClient
  #endif
  import Synchronization

  /// Bounded diagnostic snapshots of the engine-wide processing state; never changes processing.
  public final class MediaProcessingTimeline: Sendable {
    /// The boundary at which a snapshot was read.
    public enum Boundary: String, Encodable, Sendable {
      case captureOptionsApplying, captureOptionsApplied, engineAvailabilityApplying,
        engineAvailabilityApplied, engineDidCreate, engineWillEnable, engineWillStart,
        engineDidStop, engineDidDisable, engineWillRelease, engineWillConnectInput,
        engineWillConnectOutput, sourceRender, outputCallback, acquisition, checkRead
    }
    /// Missing requested state remains explicit rather than becoming false.
    public enum Requested: String, Encodable, Sendable {
      case unavailable, enabled, disabled
      init(_ value: Bool?) {
        self = value.map { $0 ? .enabled : .disabled } ?? .unavailable
      }
    }
    /// Requested and software-active values for one effect.
    public struct Effect: Encodable, Sendable {
      public let requested: Requested
      public let active: Bool
    }
    /// A state read bracketed by monotonic timestamps from one timeline origin.
    public struct Entry: Encodable, Sendable {
      public let boundary: Boundary
      public let seconds: Double
      public let readCompletedSeconds: Double
      public let engineRunning: Bool?
      public let aec: Effect
      public let ns: Effect
      public let agc: Effect
    }
    private struct Storage {
      var entries: [Entry] = []
      var sourceCallbacks = 0
      var outputCallbacks = 0
      var dropped = 0
    }
    private let storage = Mutex(Storage())
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now
    /// Creates a timeline without starting audio or changing capture options.
    public init() {}
    /// All retained snapshots, in monotonic read-start order.
    public var entries: [Entry] {
      storage.withLock { $0.entries.sorted { $0.seconds < $1.seconds } }
    }
    /// Number of snapshots omitted after the diagnostic storage limit.
    public var dropped: Int { storage.withLock { $0.dropped } }
    /// Reads the real shared processing state. The check uses this same returned snapshot.
    @discardableResult
    public func record(_ boundary: Boundary, engineRunning: Bool? = nil) -> Entry {
      let started = seconds()
      let state = AudioManager.shared.audioProcessingState
      let entry = Entry(
        boundary: boundary, seconds: started, readCompletedSeconds: seconds(),
        engineRunning: engineRunning,
        aec: Effect(
          requested: Requested(state.echoCancellation.requested?.isEnabled),
          active: state.echoCancellation.software.isActive),
        ns: Effect(
          requested: Requested(state.noiseSuppression.requested?.isEnabled),
          active: state.noiseSuppression.software.isActive),
        agc: Effect(
          requested: Requested(state.autoGainControl.requested?.isEnabled),
          active: state.autoGainControl.software.isActive))
      storage.withLock {
        if boundary == .engineWillConnectInput { $0.sourceCallbacks = 0 }
        if boundary == .engineWillConnectOutput { $0.outputCallbacks = 0 }
        if $0.entries.count < 512 { $0.entries.append(entry) } else { $0.dropped += 1 }
      }
      return entry
    }
    /// Samples only the first three callbacks after each graph connection.
    public func recordCallback(_ boundary: Boundary) {
      let sample = storage.withLock { state in
        switch boundary {
        case .sourceRender:
          guard state.sourceCallbacks < 3 else { return false }
          state.sourceCallbacks += 1
        case .outputCallback:
          guard state.outputCallbacks < 3 else { return false }
          state.outputCallbacks += 1
        default: return false
        }
        return true
      }
      if sample { record(boundary) }
    }
    private func seconds() -> Double {
      let value = origin.duration(to: clock.now).components
      return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
  }
#endif
