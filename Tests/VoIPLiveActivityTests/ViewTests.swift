#if os(iOS)
  import AppIntents
  import SwiftUI
  import Testing
  import VoIPCore

  @testable import VoIPLiveActivity

  /// The app's Join intent, as an app declares it.
  private struct JoinCall: JoinCallPreviewIntent {
    static let title: LocalizedStringResource = "Join Call"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = false

    @Parameter(title: "Call ID")
    var callID: String
  }

  @MainActor
  @Suite struct ViewTests {
    /// The width of the Lock Screen card on an iPhone 13 and on an iPhone 17 Pro, in points.
    nonisolated static let cardWidths: [CGFloat] = [370, 382]

    /// A joinable preview that says the most the default views say: the longest status, a timer
    /// and a snippet.
    private func display(isJoinable: Bool = true) -> CallPreviewDisplay {
      var state = firstState
      state.status = .answeredElsewhere
      state.snippet = "They asked whether you can call back after six."
      state.isJoinable = isJoinable
      return CallPreviewDisplay(
        attributes: CallPreviewAttributes(callID: callID, parties: [alice]), state: state,
        isStale: false)
    }

    /// The size that a view takes when it is offered a width, or its ideal size.
    private func size(of view: some View, width: CGFloat? = nil) throws -> CGSize {
      let renderer = ImageRenderer(content: view)
      renderer.proposedSize = ProposedViewSize(width: width, height: nil)
      return try #require(renderer.uiImage).size
    }

    @Test func joinKeepsTheSizeOfItsTitleAndSymbol() throws {
      let join = JoinButton<JoinCall>(callID: callID.rawValue, display: display())
      let ideal = try size(of: join)
      // Offered far less, as the card's status lines leave it, the button keeps its title.
      #expect(try size(of: join, width: 20) == ideal)
      #expect(ideal.width > ideal.height)
    }

    @Test(arguments: cardWidths)
    func joinFitsBesideTheStatusWithoutMakingTheCardTaller(width: CGFloat) throws {
      let withJoin = try size(
        of: CallPreviewView<JoinCall>(callID: callID, display: display()), width: width)
      let withoutJoin = try size(
        of: CallPreviewView<JoinCall>(callID: callID, display: display(isJoinable: false)),
        width: width)
      #expect(withJoin.width == width)
      // The status may shrink a little beside Join, but Join is never taller than the text.
      #expect(withJoin.height <= withoutJoin.height)
    }
  }
#endif
