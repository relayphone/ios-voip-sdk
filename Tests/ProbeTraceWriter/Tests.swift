import Foundation

@main
enum ProbeTraceTests {
  static func main() throws {
    let json = try JSONSerialization.data(withJSONObject: ["event": "host.record", "padding": String(repeating: "x", count: 500)])
    let expected = Data("PROBE ".utf8) + json + Data("\n".utf8)
    precondition(expected.count > 512 && expected.count < ProbeTraceWriter.maximumLineBytes)
    let foreign = Data("WARNING: independent foreign diagnostic\n".utf8)
    var calls: [Data] = []
    var interleaved = Data()
    let publish: (Data) -> Int = { bytes in
      calls.append(bytes); interleaved.append(bytes); interleaved.append(foreign)
      return bytes.count
    }
    // This deterministically models the retained split-record failure: foreign
    // output arrives between publication boundaries, never repairs old evidence.
    _ = publish(Data("PROBE ".utf8)); _ = publish(json); _ = publish(Data("\n".utf8))
    precondition(probeJSONIsMalformed(interleaved))
    calls = []; interleaved = Data()
    precondition(ProbeTraceWriter.emit(json, writer: publish))
    precondition(calls == [expected] && !probeJSONIsMalformed(interleaved))

    for result in [-1, expected.count - 1] {
      var attempts = 0
      precondition(!ProbeTraceWriter.emit(json) { _ in attempts += 1; return result })
      precondition(attempts == 1) // No retry can publish a second fragment.
    }
    let boundary = Data(repeating: 120, count: ProbeTraceWriter.maximumLineBytes - 7)
    var attempts = 0
    precondition(ProbeTraceWriter.emit(boundary) { bytes in
      attempts += 1; precondition(bytes.count == ProbeTraceWriter.maximumLineBytes); return bytes.count
    })
    precondition(!ProbeTraceWriter.emit(boundary + Data([120])) { _ in attempts += 1; return 0 })
    precondition(attempts == 1)
    let defaultJSON = try JSONSerialization.data(withJSONObject: ["event": "host.defaultWrite"])
    precondition(ProbeTraceWriter.emit(defaultJSON))
    print("{\"success\":true,\"classification\":\"host-only probe publication controls\",\"checks\":[\"split-publication-interleaving-red\",\"one-complete-publication-green\",\"above-512-byte-record-preserved\",\"failed-write-no-retry\",\"short-write-no-retry\",\"bounded-line-and-oversize-refusal\",\"actual-default-stderr-frame\"]}")
  }

  private static func probeJSONIsMalformed(_ bytes: Data) -> Bool {
    for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") where line.hasPrefix("PROBE ") {
      if (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))) == nil { return true }
    }
    return false
  }
}
