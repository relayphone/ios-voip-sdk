@main struct ActivitySelectionTests {
  static func main() {
    let a = FocusActivityIdentity(activityID: "a", surfaceID: "one")
    let b = FocusActivityIdentity(activityID: "b", surfaceID: "two")
    precondition(chooseFocusActivity(expected: nil, available: []) == .create)
    precondition(chooseFocusActivity(expected: nil, available: [a]) == .reuse(0))
    precondition(chooseFocusActivity(expected: a, available: [a]) == .reuse(0))
    precondition(chooseFocusActivity(expected: a, available: []) == .missing)
    precondition(chooseFocusActivity(expected: a, available: [b]) == .missing)
    precondition(chooseFocusActivity(expected: a, available: [a, b]) == .ambiguous)
    print("Activity identity selection: 6 cases passed")
  }
}
