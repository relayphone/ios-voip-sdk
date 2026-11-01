#if os(iOS)
  import AppIntents
  public import SwiftUI
  public import WidgetKit

  #if SWIFT_PACKAGE
    import VoIPCore
  #endif

  /// The default views of a call preview's Live Activity: the caller, what is happening, a timer
  /// from the call's start, the latest snippet, and Join.
  ///
  /// Show it from the app's widget extension, with the app's ``JoinCallPreviewIntent``:
  ///
  /// ```swift
  /// import SwiftUI
  /// import VoIPLiveActivity
  /// import WidgetKit
  ///
  /// struct CallPreviewWidget: Widget {
  ///   var body: some WidgetConfiguration {
  ///     ActivityConfiguration(for: CallPreviewAttributes.self) { context in
  ///       CallPreviewView(context, join: JoinCall.self)
  ///     } dynamicIsland: { context in
  ///       CallPreviewView.dynamicIsland(context, join: JoinCall.self)
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// The view is the Lock Screen presentation, and ``dynamicIsland(_:join:)`` gives the Dynamic
  /// Island's compact, minimal and expanded presentations. They show the first party's display
  /// name, or its handle; the content state's `statusText`, or a description of its status; a
  /// timer from `startedAt` until the call ends; the snippet; and Join while the state is
  /// joinable. When the state is out of date, because no update arrived within its stale time,
  /// they say that updates are delayed instead of showing a snippet that looks live.
  ///
  /// The view's own words are English. The widget extension can translate them in its
  /// `Localizable` strings, under the keys "Call silenced", "Answered on another device", "Call in
  /// progress", "Call ended", "Updates delayed", "Unknown caller" and "Join".
  public struct CallPreviewView<Join: JoinCallPreviewIntent>: View {
    private let callID: String
    private let display: CallPreviewDisplay

    /// Creates the Lock Screen presentation of a call preview's Live Activity.
    ///
    /// - Parameters:
    ///   - context: The Live Activity, as `ActivityConfiguration` passes it.
    ///   - join: The app's intent that joins the call.
    public init(_ context: ActivityViewContext<CallPreviewAttributes>, join: Join.Type) {
      self.init(
        callID: context.attributes.callID,
        display: CallPreviewDisplay(
          attributes: context.attributes, state: context.state, isStale: context.isStale))
    }

    /// Creates the Lock Screen presentation from what it shows, which tests can make without a
    /// Live Activity.
    init(callID: CallID, display: CallPreviewDisplay) {
      self.callID = callID.rawValue
      self.display = display
    }

    /// The Lock Screen presentation.
    public var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          CallSymbol(display: display)
            .font(.title2)
            .frame(width: 44, height: 44)
            .background(.green.opacity(0.2), in: .circle)
          VStack(alignment: .leading, spacing: 2) {
            CallerName(display: display).font(.headline)
            StatusLines(display: display).font(.subheadline)
          }
          .layoutPriority(1)
          Spacer(minLength: 8)
          JoinButton<Join>(callID: callID, display: display)
        }
        Details(display: display)
      }
      .padding(16)
    }

    /// The Dynamic Island's presentations of a call preview's Live Activity.
    ///
    /// The compact presentation shows the call's symbol and the timer, the minimal one the
    /// symbol, and the expanded one the caller, what is happening, the snippet and Join.
    ///
    /// - Parameters:
    ///   - context: The Live Activity, as `ActivityConfiguration` passes it.
    ///   - join: The app's intent that joins the call.
    /// - Returns: The Dynamic Island's presentations.
    public static func dynamicIsland(
      _ context: ActivityViewContext<CallPreviewAttributes>, join: Join.Type
    ) -> DynamicIsland {
      let callID = context.attributes.callID.rawValue
      let display = CallPreviewDisplay(
        attributes: context.attributes, state: context.state, isStale: context.isStale)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          CallSymbol(display: display).font(.title2).padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          JoinButton<Join>(callID: callID, display: display)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            CallerName(display: display).font(.headline)
            StatusLines(display: display).font(.subheadline)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Details(display: display).frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        CallSymbol(display: display)
      } compactTrailing: {
        if let start = display.timerStart {
          Text(start, style: .timer)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 48)
        }
      } minimal: {
        CallSymbol(display: display)
      }
      .keylineTint(.green)
    }
  }

  /// The call's symbol: a phone, a video camera, or a phone hung up once it ended.
  private struct CallSymbol: View {
    let display: CallPreviewDisplay

    var body: some View {
      Image(systemName: display.symbol)
        .foregroundStyle(display.timerStart == nil ? Color.secondary : Color.green)
        .accessibilityHidden(true)
    }
  }

  /// The first party's name.
  private struct CallerName: View {
    let display: CallPreviewDisplay

    var body: some View {
      Group {
        if let name = display.name {
          Text(verbatim: name)
        } else {
          Text("Unknown caller")
        }
      }
      .lineLimit(1)
    }
  }

  /// What is happening, and below it the time since the call started.
  ///
  /// Each has a line of its own: a timer takes all the width it is offered, and beside it and
  /// Join the status was cut short on an iPhone 13. The status may also shrink a little before it
  /// is cut.
  private struct StatusLines: View {
    let display: CallPreviewDisplay

    var body: some View {
      Group {
        Group {
          switch display.status {
          case .text(let text): Text(verbatim: text)
          case .described(let description): Text(description)
          }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        if let start = display.timerStart {
          Text(start, style: .timer)
            .monospacedDigit()
            .lineLimit(1)
            .multilineTextAlignment(.leading)
        }
      }
      .foregroundStyle(.secondary)
    }
  }

  /// The snippet, or that updates are delayed.
  private struct Details: View {
    let display: CallPreviewDisplay

    var body: some View {
      if display.showsDelay {
        Label("Updates delayed", systemImage: "clock.badge.exclamationmark")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else if let snippet = display.snippet {
        Text(verbatim: snippet)
          .font(.footnote)
          .lineLimit(2)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Join, while the state is joinable.
  ///
  /// The button keeps the size of its title and symbol. Beside a long status, which the card lays
  /// out first, it was otherwise squeezed to its symbol in a pill as tall as the card, without the
  /// title or the accessibility label that VoiceOver and UI tests find it by.
  struct JoinButton<Join: JoinCallPreviewIntent>: View {
    let callID: String
    let display: CallPreviewDisplay

    var body: some View {
      if display.showsJoin {
        Button(intent: Join(callID: CallID(rawValue: callID))) {
          Label("Join", systemImage: display.symbol)
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(.green)
        .fixedSize()
        .accessibilityLabel(Text("Join"))
      }
    }
  }
#endif
