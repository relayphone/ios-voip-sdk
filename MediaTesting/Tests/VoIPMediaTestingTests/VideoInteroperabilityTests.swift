import CryptoKit
import Foundation
import Testing

@testable import VoIPMediaTesting

@Suite("Host video marker interoperability")
struct VideoInteroperabilityTests {
  @Test func sourcePixelsMatchTheHostWireVector() throws {
    let marker = try VideoMarker(
      fixture: #require(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")),
      direction: .uplink, epoch: 7, counter: .max, sourceTimeUs: 9_007_199_254_740_991)
    let luma = try marker.luma(width: 160, height: 120)
    let digest = SHA256.hash(data: Data(luma)).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "94ba28480beb3d98dcb027a5bfca34428cdd0715b3a0a8c43ee54555e913f51a")
    #expect(try VideoMarker.decode(luma: luma, width: 160, height: 120, stride: 160) == marker)
  }
}
