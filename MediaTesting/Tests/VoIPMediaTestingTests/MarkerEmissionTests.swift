import Testing

@testable import VoIPMediaTesting

@Suite("Fresh marker source")
struct MarkerEmissionTests {
  private func render(_ source: MarkerEmission, count: Int) -> [Float] {
    source.render { samples, position in
      let result = (0..<count).map { samples[Int((position + Int64($0)) % Int64(samples.count))] }
      position += Int64(count)
      return result
    }
  }

  @Test(arguments: [8000.0, 48000.0])
  func replacementChangesActualSamplesAndRestartsCycle(rate: Double) {
    let first = Array(repeating: 650.0, count: 12)
    let second = Array(repeating: 1850.0, count: 12)
    let source = MarkerEmission(frequencies: first)
    source.configure(rate: rate)
    let count = Int(rate * 1.02)
    let original = render(source, count: count + 137)
    source.replace(frequencies: second)
    let replacement = render(source, count: count)
    #expect(
      replacement
        == (0..<count).map {
          MarkerSignal.emissionSample(Int64($0), rate: rate, frequencies: second)
        })
    #expect(Array(original.prefix(count)) != replacement)
    #expect(source.generatedSamples == Int64(count * 2 + 137))
    source.configure(rate: 16000)
    #expect(
      render(source, count: 16320)
        == (0..<16320).map {
          MarkerSignal.emissionSample(Int64($0), rate: 16000, frequencies: second)
        })
  }

  @Test func concurrentPhaseChangesNeverMixCyclesWithinOneRender() async {
    let first = Array(repeating: 650.0, count: 12)
    let second = Array(repeating: 1850.0, count: 12)
    let source = MarkerEmission(frequencies: first)
    source.configure(rate: 8000)
    let count = 8160
    let expected = [first, second].map { frequencies in
      (0..<count).map {
        MarkerSignal.emissionSample(Int64($0), rate: 8000, frequencies: frequencies)
      }
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for index in 0..<20 {
          source.replace(frequencies: index.isMultiple(of: 2) ? second : first)
        }
      }
      group.addTask {
        for _ in 0..<20 { #expect(expected.contains(render(source, count: count))) }
      }
    }
    #expect(source.generatedSamples == Int64(count * 20))
  }
}
