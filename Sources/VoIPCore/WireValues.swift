enum WireValues {
  static func isID(_ value: String) -> Bool {
    let scalars = value.unicodeScalars
    guard let first = scalars.first, let last = scalars.last,
      !isWhitespace(first), !isWhitespace(last), scalars.count <= 256
    else { return false }
    return !scalars.contains { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) }
  }

  static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F,
      0x205F, 0x3000, 0xFEFF:
      true
    default: false
    }
  }

  static func isUTCMillisecondTimestamp(_ value: String) -> Bool {
    guard
      let match = value.wholeMatch(
        of: #/([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})\.[0-9]{3}Z/#
      ), let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
      let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6),
      (1...12).contains(month), hour < 24, minute < 60, second < 60
    else { return false }

    let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let monthLengths = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return (1...monthLengths[month - 1]).contains(day)
  }
}
