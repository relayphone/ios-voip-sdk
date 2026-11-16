import Testing
import VoIPCore

@testable import VoIPConversationsMapping

struct VideoUpdateTests {
  @Test func videoOnlyAndAbsentMembersAreValid() throws {
    let value = try ConversationVideoUpdate(.object(["video": .bool(true)]))
    #expect(value.video == true)
    #expect(value.members == nil)
    #expect(value.parties.isEmpty)
  }

  @Test(arguments: [JSONValue.string("true"), .null, .number(1)])
  func malformedVideoRejects(value: JSONValue) {
    #expect(throws: CommandError.self) {
      try ConversationVideoUpdate(.object(["video": value]))
    }
  }

  @Test func malformedMixedUpdateRejectsBeforeApplication() {
    #expect(throws: CommandError.self) {
      try ConversationVideoUpdate(.object(["video": .bool(true), "members": .array([])]))
    }
  }
  @Test @VoIPActor func updatedConfigurationSurvivesReactivationWithoutReorderingCalls() {
    var applied: [Bool] = []
    let recorder = VideoConfigurationRecorder()
    let cache = CallAudioConfiguration<Bool> { recorder.values.append($0) }
    let first = CallID(rawValue: "first")
    let second = CallID(rawValue: "second")
    cache.remember(false)
    cache.prepared(first, configuration: false)
    cache.updated(first, configuration: true)
    cache.activate()
    cache.deactivate()
    cache.activate()
    applied = recorder.values
    #expect(applied == [true, true])
    cache.prepared(second, configuration: false)
    cache.updated(first, configuration: true)
    cache.activate()
    #expect(recorder.values.last == false)
    // Ownership switches to first while second remains prepared/held.
    cache.select(first)
    cache.activate()
    cache.deactivate()
    cache.activate()
    #expect(recorder.values.suffix(2) == [true, true])
  }
}

@VoIPActor private final class VideoConfigurationRecorder { var values: [Bool] = [] }
