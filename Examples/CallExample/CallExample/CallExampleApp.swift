import SwiftUI

/// A minimal app that presents calls with ios-voip-sdk.
@main
struct CallExampleApp: App {
  /// Created at launch, so that the SDK is running when a VoIP push launches the app.
  @State private var calls = Calls()

  var body: some Scene {
    WindowGroup {
      ContentView(calls: calls)
    }
  }
}
