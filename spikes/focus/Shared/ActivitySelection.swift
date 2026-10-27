// Pure selection policy, shared with the host-side regression test.
struct FocusActivityIdentity: Equatable {
  let activityID: String
  let surfaceID: String
}

enum FocusActivityChoice: Equatable {
  case create, reuse(Int), missing, ambiguous
}

func chooseFocusActivity(expected: FocusActivityIdentity?, available: [FocusActivityIdentity]) -> FocusActivityChoice {
  guard available.count <= 1 else { return .ambiguous }
  if let expected {
    guard available.first == expected else { return .missing }
    return .reuse(0)
  }
  return available.isEmpty ? .create : .reuse(0)
}
