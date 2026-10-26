// macOS-only acoustic evidence. Compilation/--dry-run never opens a microphone.
import AVFoundation
import Foundation

func option(_ name: String) -> String? {
  let args = CommandLine.arguments
  guard let index = args.firstIndex(of: name), args.count > index + 1 else { return nil }
  return args[index + 1]
}
if CommandLine.arguments.contains("--dry-run") {
  print("Host microphone: check permission; capture RMS envelope; compare C00 calibration; never classify energy as proven ringing")
  exit(0)
}
if CommandLine.arguments.contains("--authorize") {
  let done = DispatchSemaphore(value: 0)
  AVCaptureDevice.requestAccess(for: .audio) { _ in done.signal() }
  _ = done.wait(timeout: .now() + 30)
  print(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Microphone authorized" : "Visual evidence only")
  exit(0)
}
guard let output = option("--output"), let seconds = Double(option("--seconds") ?? "40"),
  seconds.isFinite, (5...180).contains(seconds) else {
  fputs("usage: listen --output PATH --seconds 5..180 [--calibration PATH] [--positive]\n", stderr); exit(2)
}
let destination = URL(fileURLWithPath: output)
func write(_ value: [String: Any]) {
  if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
    try? data.write(to: destination, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
  }
}
guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
  write(["mode": "visual evidence only", "reason": "microphone permission unavailable"]); exit(0)
}
final class Envelope: @unchecked Sendable {
  let lock = NSLock()
  var samples: [[String: Double]] = []
  var last = 0.0
  func append(_ rms: Double) {
    lock.lock(); defer { lock.unlock() }
    let now = Date().timeIntervalSince1970
    guard now - last >= 0.1, samples.count < 2000 else { return }
    last = now; samples.append(["wallTime": now, "rms": rms])
  }
}
let engine = AVAudioEngine(), envelope = Envelope()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
guard format.channelCount > 0, format.sampleRate > 0 else {
  write(["mode": "visual evidence only", "reason": "no microphone input"]); exit(0)
}
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
  guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
  let data = channels[0], count = Int(buffer.frameLength)
  var total = 0.0
  for index in 0..<count { total += Double(data[index]) * Double(data[index]) }
  envelope.append(sqrt(total / Double(count)))
}
do { try engine.start() } catch {
  write(["mode": "visual evidence only", "reason": "microphone engine unavailable"]); exit(0)
}
let started = Date().timeIntervalSince1970
try? Data("ready".utf8).write(to: URL(fileURLWithPath: output + ".ready"), options: .atomic)
Thread.sleep(forTimeInterval: seconds)
engine.stop(); input.removeTap(onBus: 0)
envelope.lock.lock(); let samples = envelope.samples; envelope.lock.unlock()
func percentile(_ values: [Double]) -> Double {
  let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
}
let quiet = percentile(samples.filter { $0["wallTime"]! - started < 3 }.map { $0["rms"]! })
let signal = percentile(samples.filter { $0["wallTime"]! - started >= 5 }.map { $0["rms"]! })
var result: [String: Any] = ["mode": "acoustic energy proxy", "startedAt": started, "samples": samples,
  "quietP95": quiet, "signalP95": signal, "ringtoneConfirmed": false,
  "limitations": "Ambient noise and microphone placement can cause false positives/negatives; no recording or speech recognition"]
if CommandLine.arguments.contains("--positive") {
  result["calibrationValid"] = samples.count >= 50 && signal > max(quiet * 3, 0.001)
  result["threshold"] = max(quiet * 3, signal * 0.25, 0.001)
} else if let path = option("--calibration"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
  let calibration = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
  calibration["calibrationValid"] as? Bool == true, let threshold = calibration["threshold"] as? Double {
  result["calibrationValid"] = true
  result["energyAboveBaseline"] = signal > max(threshold, quiet * 3)
} else {
  result["calibrationValid"] = false; result["mode"] = "visual evidence only"
  result["reason"] = "valid C00 positive calibration unavailable"
}
write(result)
