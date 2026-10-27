import Foundation

// A nil result means the stored number cannot safely establish absence.
func contactPhoneMatch(candidate: String, raw: String) -> Bool? {
  let digits = raw.filter { $0.isASCII && $0.isNumber }
  guard raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isWhitespace || "+-()".contains($0)) }),
    digits.count >= 4 else { return nil }
  let overlap = min(candidate.count, digits.count, 7)
  return overlap >= 4 && digits.contains(candidate.suffix(overlap))
}
