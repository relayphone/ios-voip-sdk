import Foundation

// Pure matcher: inputs stay in the UI process; no labels are exported.
func exactCadenceMatch(observationID: String, revision: Int, allLabels: [String], visibleLabels: [String]) -> Bool {
  guard let id = UUID(uuidString: observationID), id.uuidString.lowercased() == observationID,
        (1...1_000_000).contains(revision) else { return false }
  let expected = "Synthetic cadence \(observationID) revision \(revision)"
  return allLabels.filter { $0 == "Revision \(revision)" }.count == 1 &&
    allLabels.filter { $0 == expected }.count == 1 && visibleLabels.filter { $0 == expected }.count == 1
}
