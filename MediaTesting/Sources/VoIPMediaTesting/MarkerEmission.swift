import Foundation
import Synchronization

// Pure sample calculation shared by the capture callback and native parity checks.
enum MarkerSignal {
  static func emissionSample(_ index: Int64, rate: Double, frequencies: [Double]) -> Float {
    let pre = Int64((rate * 3 / 20).rounded(.toNearestOrAwayFromZero))
    let post = pre + Int64(rate / 50 * 36)
    let cycle = Int64(rate / 50 * 51)
    let position = index % cycle
    if position >= pre && position < post {
      return sample(position - pre, rate: rate, frequencies: frequencies)
    }
    let local = Double(position < pre ? position : position - post)
    let edge = position < pre ? local : Double(cycle - position)
    let fade = min(1, edge / (rate / 200))
    let envelope = 0.5 * (1 - cos(.pi * fade))
    return Float(0.2 * envelope * sin(2 * .pi * 400 * local / rate))
  }
  static func sample(_ index: Int64, rate: Double, frequencies: [Double]) -> Float {
    let slotSamples = Int64(rate / 50 * 3)
    let slot = Int(index / slotSamples) % frequencies.count
    let local = Double(index % slotSamples)
    let fade = min(1, min(local, Double(slotSamples) - local) / (rate / 200))
    let envelope = 0.5 * (1 - cos(.pi * fade))
    return Float(0.2 * envelope * sin(2 * .pi * frequencies[slot] * local / rate))
  }
}

/// Source state shared by graph setup, phase changes and the actual audio callback.
final class MarkerEmission: Sendable {
  private struct State {
    var frequencies: [Double]
    var rate = 48000.0
    var samples: [Float] = []
    var index: Int64 = 0
    var total: Int64 = 0
    var revision: UInt64 = 0
  }
  private let state: Mutex<State>
  init(frequencies: [Double]) {
    Self.validate(frequencies)
    state = Mutex(State(frequencies: frequencies))
    configure(rate: 48000)
  }
  var generatedSamples: Int64 { state.withLock { $0.total } }
  private static func validate(_ frequencies: [Double]) {
    precondition(
      frequencies.count == 12 && frequencies.allSatisfy { [650, 950, 1350, 1850].contains($0) })
  }
  private static func samples(rate: Double, frequencies: [Double]) -> [Float] {
    (0..<Int(rate / 50 * 51)).map {
      MarkerSignal.emissionSample(Int64($0), rate: rate, frequencies: frequencies)
    }
  }
  func configure(rate: Double) {
    precondition(rate >= 8000 && rate <= 96000 && rate.truncatingRemainder(dividingBy: 50) == 0)
    while true {
      let snapshot = state.withLock { ($0.frequencies, $0.revision) }
      let samples = Self.samples(rate: rate, frequencies: snapshot.0)
      let installed = state.withLock {
        guard $0.revision == snapshot.1 else { return false }
        $0.rate = rate
        $0.samples = samples
        $0.index = 0
        $0.revision &+= 1
        return true
      }
      if installed { return }
    }
  }
  func replace(frequencies: [Double]) {
    Self.validate(frequencies)
    while true {
      let snapshot = state.withLock { ($0.rate, $0.revision) }
      // Synthesis stays off the render lock. A simultaneous graph change retries at its real rate.
      let samples = Self.samples(rate: snapshot.0, frequencies: frequencies)
      let installed = state.withLock {
        guard $0.revision == snapshot.1 else { return false }
        $0.frequencies = frequencies
        $0.samples = samples
        $0.index = 0
        $0.revision &+= 1
        return true
      }
      if installed { return }
    }
  }
  func render<T>(_ body: ([Float], inout Int64) -> T) -> T {
    state.withLock {
      let before = $0.index
      let result = body($0.samples, &$0.index)
      $0.total += $0.index - before
      return result
    }
  }
}
