import ActivityKit
import SwiftUI
import WidgetKit

@main struct FocusWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FocusAttributes.self) { context in
      VStack(alignment: .leading) {
        Text("Focus Probe · synthetic transcript").font(.headline)
        if context.isStale { Text("Updates delayed") }
        else { Text(context.state.excerpt).privacySensitive() }
        Text("Revision \(context.state.revision)").font(.caption)
      }.padding().activityBackgroundTint(.black).activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.center) {
          if context.isStale { Text("Updates delayed") }
          else { Text(context.state.excerpt).privacySensitive() }
        }
      } compactLeading: { Image(systemName: "captions.bubble") }
        compactTrailing: { Text("\(context.state.revision)") }
        minimal: { Image(systemName: context.isStale ? "clock" : "captions.bubble") }
    }
  }
}
