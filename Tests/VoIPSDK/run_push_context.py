#!/usr/bin/env python3
"""Compile exact simulator context types on the host; no native app or push run."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    simulator = (ROOT / 'Sources/VoIPSDK/SimulatorSupport.swift').read_text()
    engine = (ROOT / 'Sources/Engine/RuntimeEngine.swift').read_text()
    contexts = re.findall(r'enum SimulatorPushContext \{\n.*?\n\}', simulator, re.S)
    associations = re.findall(r'private struct IncomingPushAssociations \{\n.*?\n\}', engine, re.S)
    assert len(contexts) == len(associations) == 1, 'one production context and association type is required'
    production = contexts[0] + '\n' + associations[0]
    tests = r'''
private actor Bridge {
  var associations = IncomingPushAssociations()
  func associate(_ id: UUID) -> Bool {
    guard let pushID = SimulatorPushContext.pushIdentifier else { return false }
    return associations.associate(id, pushID: pushID)
  }
  func consume(_ id: UUID) -> IncomingPushAssociations.Resolution { associations.consume(id) }
}
@main struct ContextTests {
  static func main() async {
    precondition(SimulatorPushContext.pushIdentifier == nil)
    let unrelated = Task { await Task.yield(); return SimulatorPushContext.pushIdentifier }
    await SimulatorPushContext.$pushIdentifier.withValue("push-A") {
      await Task.yield()
      precondition(SimulatorPushContext.pushIdentifier == "push-A")
      let child = Task { await Task.yield(); return SimulatorPushContext.pushIdentifier }
      let inherited = await child.value
      precondition(inherited == "push-A", "child report Task must inherit callback context")
      let detached = Task.detached { SimulatorPushContext.pushIdentifier }
      let detachedValue = await detached.value
      precondition(detachedValue == nil, "unrelated work must not inherit an active global push")
    }
    let unrelatedValue = await unrelated.value
    precondition(unrelatedValue == nil && SimulatorPushContext.pushIdentifier == nil)
    let bridge = Bridge()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<32 {
        group.addTask {
          let id = UUID(), push = "overlap-\(index)"
          await SimulatorPushContext.$pushIdentifier.withValue(push) {
            await Task.yield()
            let associated = await bridge.associate(id)
            precondition(associated)
            await Task.yield()
            let consumed = await bridge.consume(id)
            precondition(consumed == .associated(push), "concurrent UUIDs must keep their own push")
            let repeated = await bridge.consume(id)
            precondition(repeated == .absent, "report association is consumed once")
          }
        }
      }
    }
    var pending = IncomingPushAssociations()
    let failed = UUID(), other = UUID(), conflicted = UUID()
    precondition(!pending.associate(failed, pushID: ""))
    precondition(pending.associate(failed, pushID: "push-A"))
    precondition(pending.associate(other, pushID: "push-B"))
    pending.complete(pushID: "push-A")
    precondition(pending.consume(failed) == .absent, "a failed report must not leave context behind")
    precondition(pending.consume(other) == .associated("push-B"), "completion cannot clear another push")
    precondition(pending.associate(failed, pushID: "reused"))
    precondition(pending.consume(failed) == .associated("reused"))
    precondition(pending.associate(conflicted, pushID: "first"))
    precondition(!pending.associate(conflicted, pushID: "second"))
    precondition(pending.consume(conflicted) == .ambiguous, "ambiguous same-UUID overlap must not guess")
    pending.complete(pushID: "first")
    precondition(pending.consume(conflicted) == .ambiguous, "ambiguity remains until all matching pushes complete")
    pending.complete(pushID: "first")
    pending.complete(pushID: "second")
    precondition(pending.consume(conflicted) == .absent)
    let early = UUID(), samePushOtherUUID = UUID()
    precondition(pending.associate(early, pushID: "early-rejected"))
    precondition(pending.associate(samePushOtherUUID, pushID: "early-rejected"))
    pending.finish(early, pushID: "unrelated")
    // A report rejected before the runtime hook finishes before PushKit completion.
    pending.finish(early, pushID: "early-rejected")
    precondition(pending.associate(early, pushID: "next-queued-report"), "next serialized report cannot inherit a rejected attempt")
    pending.finish(early, pushID: "early-rejected")
    precondition(pending.consume(early) == .associated("next-queued-report"), "an old finish cannot clear a successor")
    precondition(pending.consume(samePushOtherUUID) == .associated("early-rejected"), "report finish is scoped to UUID and push identifier")
    precondition(pending.associate(conflicted, pushID: "third"))
    precondition(!pending.associate(conflicted, pushID: "fourth"))
    pending.finish(conflicted, pushID: "third")
    precondition(pending.consume(conflicted) == .ambiguous, "partial report finish must retain ambiguity")
    pending.finish(conflicted, pushID: "fourth")
    precondition(pending.consume(conflicted) == .absent)
    print("passed: task suspension, child inheritance, unrelated/detached work, 32 concurrent UUIDs, once-consumption, matching cleanup, UUID reuse, ambiguous-overlap refusal, early-report settlement, stale-finish isolation")
  }
}
'''
    with tempfile.TemporaryDirectory(prefix='ios-voip-push-context-') as temporary:
        out = Path(temporary)
        source = out / 'context.swift'
        source.write_text('import Foundation\n' + production + '\n' + tests)
        binary = out / 'context'
        result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                                 '-parse-as-library', str(source), '-o', str(binary)], capture_output=True, text=True, timeout=60)
        if result.returncode: raise RuntimeError(result.stdout + result.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
        if result.returncode or not result.stdout.startswith('passed:'): raise RuntimeError(result.stdout + result.stderr)
        print(json.dumps(dict(success=True, classification='host concurrency controls; no native PushKit acceptance',
                             result=result.stdout.strip(), productionSHA256=hashlib.sha256(production.encode()).hexdigest(),
                             sourceFiles={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
                                          [ROOT / 'Sources/VoIPSDK/SimulatorSupport.swift', ROOT / 'Sources/VoIPSDK/PushService.swift',
                                           ROOT / 'Sources/Engine/RuntimeEngine.swift', Path(__file__)]}), indent=2))


if __name__ == '__main__':
    main()
