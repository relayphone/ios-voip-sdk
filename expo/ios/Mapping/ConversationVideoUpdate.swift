// Parsed before any side effect, so invalid mixed updates cannot partially change video.
#if SWIFT_PACKAGE
  import VoIPCore
#endif

struct ConversationVideoUpdate {
  let video: Bool?
  let members: [JSONValue]?
  let parties: [Party]

  init(_ report: JSONValue) throws(CommandError) {
    if let value = report["video"] {
      guard let enabled = value.bool else { throw .invalidArguments }
      video = enabled
    } else {
      video = nil
    }
    if let value = report["members"] {
      guard let values = value.array, !values.isEmpty else { throw .invalidArguments }
      var parsed: [Party] = []
      for value in values { parsed.append(try Party(participant: value)) }
      members = values
      parties = parsed
    } else {
      members = nil
      parties = []
    }
  }
}
