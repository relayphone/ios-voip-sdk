import Foundation
import os
import VoIPPlatform
import RouteMediaInterop

public struct AVAudioSessionPortDescription: Sendable {
  public struct Port: Sendable { public let rawValue: String }
  public let uid: String
  public let portName: String
  public let portType: Port
  public init(_ uid: String, _ name: String, _ type: String) {
    self.uid = uid; portName = name; portType = Port(rawValue: type)
  }
}
public struct AVAudioSessionRouteDescription: Sendable {
  public let outputs: [AVAudioSessionPortDescription]
}
public final class AVAudioSession: Sendable {
  public enum Category: Sendable { case playAndRecord }
  public enum Mode: Sendable { case voiceChat }
  public struct CategoryOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let allowBluetoothHFP = CategoryOptions(rawValue: 1)
  }
  public enum PortOverride: Sendable { case none, speaker }
  public enum FixtureError: Error { case setterRejected, routeSetterOutsideConfigurationLock }
  private struct State { var writes = 0; var reject = false; var reads = 0; var configurations = 0 }
  private let state = OSAllocatedUnfairLock(initialState: State())
  public static let fixture = AVAudioSession()
  public static let routeChangeNotification = Notification.Name("HostRouteChange")
  public static let availableInputsChangeNotification = Notification.Name("HostAvailableInputsChange")
  public static func sharedInstance() -> AVAudioSession {
    precondition(VSAudioSessionIsOnQueue() && !Thread.isMainThread); return fixture
  }
  public var availableInputs: [AVAudioSessionPortDescription]? {
    precondition(VSAudioSessionIsOnQueue()); state.withLock { $0.reads += 1 }
    return [.init("built-in", "Microphone", "MicrophoneBuiltIn")]
  }
  public var currentRoute: AVAudioSessionRouteDescription {
    precondition(VSAudioSessionIsOnQueue())
    return .init(outputs: [.init("receiver", "Receiver", "Receiver")])
  }
  private func mutate() throws {
    precondition(VSAudioSessionIsOnQueue() && !Thread.isMainThread)
    guard VSRouteConfigurationLocked() else { throw FixtureError.routeSetterOutsideConfigurationLock }
    let reject = state.withLock { value in
      value.writes += 1
      let result = value.reject; value.reject = false; return result
    }
    if reject { throw FixtureError.setterRejected }
  }
  public func overrideOutputAudioPort(_ value: PortOverride) throws { try mutate() }
  public func setPreferredInput(_ value: AVAudioSessionPortDescription?) throws { try mutate() }
  public func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws {
    state.withLock { $0.configurations += 1 }
  }
  public func rejectNextSetter() { state.withLock { $0.reject = true } }
  public var writes: Int { state.withLock { $0.writes } }
  public var reads: Int { state.withLock { $0.reads } }
  public var configurations: Int { state.withLock { $0.configurations } }
}
