import Testing
import VoIPMediaTesting

@Suite("Continuous PCM silence windows")
struct SilenceWindowTests {
  private func observer(deadline: Duration = .seconds(3)) -> PCMSilenceWindows {
    PCMSilenceWindows(start: .zero, duration: .seconds(1), deadline: deadline)
  }
  private func frame(
    _ state: inout PCMSilenceWindows, at time: Duration, energy: Double = 0, frames: Int = 4800
  ) {
    state.receive(at: time, frames: frames, sampleRate: 48000, sampleCount: frames, energy: energy)
  }
  @Test func stalledAttemptThenFullCleanWindowPasses() {
    var state = observer()
    frame(&state, at: .milliseconds(100))
    frame(&state, at: .milliseconds(500))
    #expect(state.windows.count == 1)
    #expect(state.windows[0].verdict == .unobserved)
    #expect(state.windows[0].gaps[0].uncoveredSeconds > 0.29)
    for tick in 6...15 { frame(&state, at: .milliseconds(tick * 100)) }
    #expect(state.verdict == .silent)
    #expect(state.windows.count == 2)
    #expect(state.windows[1].endSeconds - state.windows[1].startSeconds == 1)
  }
  @Test func leakCannotBeErasedByGapOrLaterCleanFrames() {
    var state = observer()
    frame(&state, at: .milliseconds(400), energy: 48)
    for tick in 5...20 { frame(&state, at: .milliseconds(tick * 100)) }
    #expect(state.verdict == .leak)
    #expect(state.windows.count == 1)
    #expect(state.windows[0].gaps.count == 1)
  }
  @Test func missingCoverageUntilDeadlineIsUnobserved() {
    var state = observer(deadline: .seconds(1))
    frame(&state, at: .milliseconds(400))
    frame(&state, at: .milliseconds(800))
    state.tick(at: .seconds(1))
    #expect(state.verdict == .unobserved)
    #expect(state.windows.allSatisfy { $0.verdict == .unobserved })
    #expect(state.windows.last?.endSeconds == 1)
  }
  @Test func hundredMillisecondBuffersCoverTheirOwnDuration() {
    var state = observer()
    for tick in 1...10 { frame(&state, at: .milliseconds(tick * 100)) }
    #expect(state.verdict == .silent)
    #expect(state.windows[0].gaps.isEmpty)
  }
  @Test func frameCoverageDoesNotReplaceCallbackLiveness() {
    var state = observer()
    frame(&state, at: .milliseconds(400), frames: 19200)
    #expect(state.windows[0].gaps[0].uncoveredSeconds == 0)
    #expect(state.windows[0].gaps[0].callbackGapSeconds == 0.4)
    #expect(state.windows[0].verdict == .unobserved)
  }
  @Test func uncoveredGapAboveFortyMillisecondsRetiresWindow() {
    var state = observer()
    frame(&state, at: .milliseconds(150))
    #expect(state.windows[0].gaps[0].uncoveredSeconds > 0.04)
    #expect(state.windows[0].gaps[0].callbackGapSeconds < 0.25)
  }
  @Test func lateFramesCannotExtendBudgetAndTicksRetainLag() {
    var state = observer(deadline: .seconds(1))
    state.tick(at: .milliseconds(20))
    state.tick(at: .milliseconds(400))
    frame(&state, at: .milliseconds(1100))
    #expect(state.verdict == .unobserved)
    #expect(state.windows.last?.ticks.last?.schedulerLagSeconds == 0.36)
  }
}

extension SilenceWindowTests {
  @Test func repeatedSmallFrameDeficitsCannotAccumulateIntoSilence() {
    var state = observer()
    for tick in 1...25 { frame(&state, at: .milliseconds(tick * 40), frames: 480) }
    #expect(state.verdict != .silent)
    #expect(!state.windows.isEmpty)
    #expect(state.windows.allSatisfy { $0.verdict == .unobserved })
  }
  @Test func missingTapThroughDeadlineRecordsTrailingGap() {
    var state = observer()
    state.tick(at: .milliseconds(20))
    state.tick(at: .seconds(3))
    #expect(state.verdict == .unobserved)
    #expect(state.windows[0].gaps[0].fromSeconds == 0)
    #expect(state.windows[0].gaps[0].toSeconds == 3)
    #expect(state.windows[0].gaps[0].uncoveredSeconds == 3)
    #expect(state.windows[0].ticks.last?.schedulerLagSeconds == 2.96)
  }
}

extension SilenceWindowTests {
  @Test func ordinaryCallbackJitterDoesNotDiscardDeliveredFrames() {
    var state = observer()
    for time in [90, 200, 290, 400, 490, 600, 690, 800, 890, 1000] {
      frame(&state, at: .milliseconds(time))
    }
    #expect(state.verdict == .silent)
    #expect(state.windows.count == 1)
  }
}

extension SilenceWindowTests {
  @Test func delayedObserverReturningAfterWinnerStillRecordsSchedulerLag() {
    var state = observer()
    state.tick(at: .zero)
    frame(&state, at: .milliseconds(400))
    for tick in 5...15 { frame(&state, at: .milliseconds(tick * 100)) }
    state.tick(at: .milliseconds(1600))
    #expect(state.verdict == .silent)
    #expect(state.windows.allSatisfy { $0.ticks.last?.seconds == 1.6 })
    #expect(state.windows.allSatisfy { $0.ticks.last?.schedulerLagSeconds == 1.58 })
  }
}

extension SilenceWindowTests {
  @Test func fullWindowEndingAtFractionalClockOriginQualifies() {
    var state = observer()
    frame(&state, at: .milliseconds(400))
    for tick in 5...14 { frame(&state, at: .milliseconds(tick * 100)) }
    #expect(state.verdict == .silent)
    #expect(state.windows.count == 2)
  }
}
