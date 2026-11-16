#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  #if SWIFT_PACKAGE
    import CKSimProtocol
  #endif

  /// Invocation-local observations. Hook installation never implies registry or handler readiness.
  struct RuntimeProcessLifecycle {
    enum Boundary: Sendable {
      case entered
      case runtimeReady
      case registryReady
      case handlerReady(Int)
    }

    enum Source: String, Sendable {
      case runtimePreparation = "runtime-preparation"
      case hooksInstalled = "hooks-installed"
      case registryQueue = "registry-delivery-queue"
      case handlerAttachment = "native-handler-acknowledgement"
    }

    struct Observation: Sendable, Equatable {
      let event: ProcessLifecycleEvent
      let uptimeNanoseconds: UInt64
      let source: Source
      var generation: Int? = nil
    }

    private(set) var entered: Observation?
    private(set) var runtimeReady: Observation?
    private(set) var registryReady: Observation?
    private(set) var handlerReady: Observation?

    /// Accepts a boundary once, using its actual observation time rather than journal-write time.
    mutating func observe(_ boundary: Boundary, at uptimeNanoseconds: UInt64) -> Observation? {
      guard uptimeNanoseconds > 0 else { return nil }
      let observation: Observation
      switch boundary {
      case .entered:
        guard entered == nil else { return nil }
        observation = Observation(
          event: .entered, uptimeNanoseconds: uptimeNanoseconds, source: .runtimePreparation)
        entered = observation
      case .runtimeReady:
        guard let entered, runtimeReady == nil, uptimeNanoseconds >= entered.uptimeNanoseconds
        else {
          return nil
        }
        observation = Observation(
          event: .runtimeReady, uptimeNanoseconds: uptimeNanoseconds, source: .hooksInstalled)
        runtimeReady = observation
      case .registryReady:
        guard let entered, registryReady == nil, uptimeNanoseconds >= entered.uptimeNanoseconds
        else { return nil }
        observation = Observation(
          event: .registryReady, uptimeNanoseconds: uptimeNanoseconds, source: .registryQueue)
        registryReady = observation
      case .handlerReady(let generation):
        guard let entered, generation > 0, generation > (handlerReady?.generation ?? 0),
          uptimeNanoseconds >= entered.uptimeNanoseconds
        else { return nil }
        observation = Observation(
          event: .handlerReady, uptimeNanoseconds: uptimeNanoseconds, source: .handlerAttachment,
          generation: generation)
        handlerReady = observation
      }
      return observation
    }
  }
#endif
