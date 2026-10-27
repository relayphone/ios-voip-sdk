import Foundation

// A nil result means the stored number cannot safely establish absence.
func contactPhoneMatch(candidate: String, raw: String) -> Bool? {
  let digits = raw.filter { $0.isASCII && $0.isNumber }
  guard raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isWhitespace || "+-()".contains($0)) }),
    digits.count >= 4 else { return nil }
  let overlap = min(candidate.count, digits.count, 7)
  return overlap >= 4 && digits.contains(candidate.suffix(overlap))
}

// An unrelated or unreadable number prevents proving ownership or absence.
struct OwnedContactAudit {
  let candidate: String
  private var namedCount = 0
  private var namedNumberValid = false
  private var ambiguous = false

  mutating func record(nameMatches: Bool, numbers: [String]) {
    if nameMatches {
      namedCount += 1
      guard numbers.count == 1, let raw = numbers.first else { return }
      let digits = raw.filter { $0.isASCII && $0.isNumber }
      let isFormatted = raw.allSatisfy { $0.isASCII && ($0.isNumber || $0.isWhitespace || "+-()".contains($0)) }
      namedNumberValid = isFormatted && (digits == candidate || (candidate.count >= 10 && digits == String(candidate.suffix(10))))
      return
    }
    for raw in numbers {
      guard let matches = contactPhoneMatch(candidate: candidate, raw: raw) else {
        ambiguous = true
        continue
      }
      if matches { ambiguous = true }
    }
  }

  var result: String {
    if ambiguous { return "unavailable" }
    if namedCount == 0 { return "absent" }
    return namedCount == 1 && namedNumberValid ? "present" : "unavailable"
  }
}
