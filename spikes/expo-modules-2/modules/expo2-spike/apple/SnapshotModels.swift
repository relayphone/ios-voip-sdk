import ExpoModulesCore

enum RingingStatus: String, Enumerable, Sendable { case ringing }
enum ActiveStatus: String, Enumerable, Sendable { case active }

@Record struct RingingConversation: Sendable {
  let id: String
  let status: RingingStatus
  let caller: String
}

@Record struct ActiveConversation: Sendable {
  let id: String
  let status: ActiveStatus
  let connectedAt: Int
}

@Union enum ConversationValue: Sendable {
  case ringing(RingingConversation)
  case active(ActiveConversation)
}

@Record struct SnapshotRecord: Sendable {
  let version: Int
  let conversations: [ConversationValue]
}

// A copyable envelope avoids macro 0.22's implicit Copyable return assertion.
// Encoding copies only the retained JSI handle, preserving the frozen JS object.
struct CachedSnapshot: JavaScriptEncodable, Sendable {
  let value: JavaScriptValue.Ref
  @JavaScriptActor
  static func encode(_ value: Self, in runtime: borrowing JavaScriptRuntime) throws -> JavaScriptValue {
    value.value.withUnwrappedValue { $0.copy() } ?? .undefined()
  }
}

struct ChangeEvent: AnyArgument, JavaScriptEncodable, Sendable {
  let snapshot: CachedSnapshot
  let version: Int
  @JavaScriptActor
  static func encode(_ value: Self, in runtime: borrowing JavaScriptRuntime) throws -> JavaScriptValue {
    let object = runtime.createObject()
    object.setProperty("snapshot", value: try CachedSnapshot.encode(value.snapshot, in: runtime))
    object.setProperty("version", value: try Int.encode(value.version, in: runtime))
    return object.asValue()
  }
}
