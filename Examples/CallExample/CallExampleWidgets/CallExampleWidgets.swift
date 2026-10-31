import SwiftUI
import VoIPLiveActivity
import WidgetKit

/// The example's widget extension, which shows call previews' Live Activities.
@main
struct CallExampleWidgets: WidgetBundle {
  var body: some Widget {
    CallPreviewWidget()
  }
}

/// A call preview's Live Activity, with the SDK's default views and the app's Join intent.
struct CallPreviewWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CallPreviewAttributes.self) { context in
      CallPreviewView(context, join: JoinCall.self)
    } dynamicIsland: { context in
      CallPreviewView.dynamicIsland(context, join: JoinCall.self)
    }
  }
}
