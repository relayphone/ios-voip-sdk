import Foundation
import os
import VoIPPlatform

/// Test-owned contract facade, not a system framework or native activation proof.
public final class AVAudioSession: Sendable {
  public enum Category: Sendable { case playAndRecord }
  public enum Mode: Sendable { case voiceChat }
  public struct CategoryOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let allowBluetoothHFP = CategoryOptions(rawValue: 1)
  }
  private static let instance = AVAudioSession()
  private let configurations = OSAllocatedUnfairLock(initialState: 0)
  public init() {}
  public static func sharedInstance() -> AVAudioSession { instance }
  public func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws {
    precondition(VSAudioSessionIsOnQueue() && !Thread.isMainThread)
    configurations.withLock { $0 += 1 }
  }
  public var configurationCalls: Int { configurations.withLock { $0 } }
}
