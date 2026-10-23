import ExpoModulesCore

@ExpoModule("Expo2Spike")
public final class Expo2SpikeModule {
  @JS
  func hello() -> String {
    "Hello from the Expo Modules 2.0 Swift bridge"
  }
}
