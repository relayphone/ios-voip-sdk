import Darwin
import Foundation

/// Example acceptance transport only. One checked write avoids stdio flushing
/// and cross-descriptor publication. This is not an unconditional atomicity
/// guarantee: measured records reach 542 bytes, above Darwin's 512 PIPE_BUF.
enum ProbeTraceWriter {
  // The measured maximum is 542 bytes. Leave room for fixture metadata while
  // bounding publication; oversized/short/failed writes remain missing evidence.
  static let maximumLineBytes = 4096

  @discardableResult
  static func emit(_ json: Data, writer: (Data) -> Int = writeStandardError) -> Bool {
    guard json.count <= maximumLineBytes - 7 else { return false }
    let line = Data("PROBE ".utf8) + json + Data("\n".utf8)
    return writer(line) == line.count
  }

  private static func writeStandardError(_ line: Data) -> Int {
    line.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
  }
}
