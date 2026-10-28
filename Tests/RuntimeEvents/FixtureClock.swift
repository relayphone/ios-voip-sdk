import Foundation

// Only the LCK fixture compiles this scheduler. RuntimeEngine's state queue
// owns it; real journal timestamps and advertised action dates stay untouched.
final class RuntimeFixtureClock {
  private struct Job {
    let deadline: Int
    let order: Int
    let body: @Sendable () -> Void
  }
  private(set) var nowMS = 0
  private var order = 0
  private var jobs: [Job] = []

  func schedule(_ seconds: Double, _ body: @escaping @Sendable () -> Void) {
    precondition(seconds.isFinite && seconds >= 0)
    jobs.append(Job(deadline: nowMS + Int((seconds * 1000).rounded()), order: order, body: body))
    order += 1
  }

  func advance(_ milliseconds: Int) {
    precondition(milliseconds >= 0)
    let target = nowMS + milliseconds
    while step(toward: target) {}
  }

  // Native callers drain delegate work between steps, including jobs that a
  // delegate schedules at this same time, before moving to a later deadline.
  @discardableResult
  func step(toward target: Int) -> Bool {
    precondition(target >= nowMS)
    if let next = jobs.indices.min(by: {
      (jobs[$0].deadline, jobs[$0].order) < (jobs[$1].deadline, jobs[$1].order)
    }), jobs[next].deadline <= target {
      let job = jobs.remove(at: next)
      nowMS = job.deadline
      job.body()
      return true
    }
    nowMS = target
    return false
  }

  func cancelAll() { jobs.removeAll() }
}
