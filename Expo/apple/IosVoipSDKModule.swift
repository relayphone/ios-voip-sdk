import ExpoModulesCore

/// M0 packaging infrastructure. The public conversation bridge arrives in M1.
public final class IosVoipSDKModule: Module {
  public func definition() -> ModuleDefinition {
    Name("IosVoipSDK")

    AsyncFunction("bootstrap") { (promise: Promise) -> Void in
      Task { @MainActor in
        let active = SimulatorSupport.activateIfNeeded()
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        promise.resolve([
          "platform": "ios",
          "simulator": simulator,
          "runtimeActive": active
        ])
      }
    }
  }
}
