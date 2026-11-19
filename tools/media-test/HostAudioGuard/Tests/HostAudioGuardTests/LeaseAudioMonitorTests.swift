import CoreAudio
import Testing

@testable import HostAudioGuard

private let routes = LeaseAudioRoutes(input: "verified input", output: "verified output")

private func output(_ uid: String?, leased: Bool, virtual: Bool = false) -> ProcessAudioActivity {
  ProcessAudioActivity(
    pid: 21, executable: "Test", direction: .output, device: 30, uid: uid,
    isVirtual: virtual, belongsToSimulator: leased)
}

@Test func ignoresForeignPlaybackOnBuiltInSpeakers() {
  #expect(routes.violation(in: [output("BuiltInSpeakerDevice", leased: false)]) == nil)
}

@Test func refusesSimulatorPlaybackOnBuiltInSpeakers() {
  let activity = [
    output("BuiltInSpeakerDevice", leased: false),
    output("BuiltInSpeakerDevice", leased: true),
  ]
  #expect(routes.violation(in: activity)?.belongsToSimulator == true)
}

@Test func acceptsSimulatorInputAndOutputOnLeaseDevices() {
  let input = ProcessAudioActivity(
    pid: 22, executable: "Test", direction: .input, device: 31, uid: routes.input,
    isVirtual: true, belongsToSimulator: true)
  #expect(routes.violation(in: [input, output(routes.output, leased: true, virtual: true)]) == nil)
  #expect(routes.violation(in: [output(routes.input, leased: true, virtual: true)]) != nil)
}

@Test func refusesUnknownDeviceForSimulatorActivity() {
  #expect(routes.violation(in: [output(nil, leased: true)]) != nil)
}

@Test func toleratesAProcessThatDisappearedAndRejectsAnUnreadableLiveProcess() throws {
  let failure = GuardError.property(
    42, kAudioProcessPropertyPID, kAudioHardwareUnknownPropertyError)
  #expect(try disappearedProcess(failure, object: 42) { [41] })
  #expect(try !disappearedProcess(failure, object: 42) { [42] })
}

@Test func anUnreadableAudioObjectUsesTheLeaseProcessLookup() throws {
  let missing: () throws(GuardError) -> UInt32 = {
    throw .property(42, kAudioProcessPropertyPID, kAudioHardwareUnknownPropertyError)
  }
  #expect(try audioProcessPID(readPID: missing, reverseLookup: { 21 }) == 21)
  #expect(try audioProcessPID(readPID: missing, reverseLookup: { nil }) == nil)
}
