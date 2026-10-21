import CallKit
import Foundation

// Log in the completion itself: resuming an async task loses its queue identity.
final class ReportThreadingProbe: NSObject, CXProviderDelegate, @unchecked Sendable {
  private let provider = CXProvider(configuration: CXProviderConfiguration())
  private let queue = DispatchQueue(label: "probe.report-threading.delegate")
  private let queueKey = DispatchSpecificKey<String>()

  override init() {
    super.init()
    queue.setSpecific(key: queueKey, value: "custom")
  }

  func providerDidReset(_ provider: CXProvider) {}

  private func report(_ id: UUID, label: String) async {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: "report-threading")
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      provider.reportNewIncomingCall(with: id, update: update) { error in
        Trace.shared.log("report.incomingCompleted", [
          "label": label, "callUUID": id.uuidString, "result": describe(error),
          "onQueue": DispatchQueue.getSpecific(key: self.queueKey) ?? "other"
        ])
        continuation.resume()
      }
    }
  }

  func run() async {
    for label in ["nil", "custom"] {
      provider.setDelegate(self, queue: label == "nil" ? nil : queue)
      let id = UUID()
      await report(id, label: label + "-success")
      await report(id, label: label + "-duplicate")
      provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
    }
    provider.invalidate()
    Trace.shared.log("done")
  }
}
