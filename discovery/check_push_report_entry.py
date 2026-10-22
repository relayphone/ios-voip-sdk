#!/usr/bin/env python3
"""Host behavioral controls of exact A1 Swift methods and runtime policy; no native claim."""
from pathlib import Path
import copy
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def braced(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    for index in range(opening + 1, len(text)):
        if text[index] == '{': depth += 1
        elif text[index] == '}': depth -= 1
        if depth == 0: return text[start:index + 1]
    raise AssertionError('unterminated production type')


POLICY = r'''
@main struct PolicyTests {
  static func main() {
    var policy = PushReportingObligations()
    precondition(policy.receive("required", required:true))
    let red = policy.returned("required")
    precondition(red.required && !red.reportEntered && red.violation == "required-report-missing-at-callback-return")
    policy.entered("required")
    let late = policy.completed("required")
    precondition(late.reportEntered && late.violation == nil, "a late report does not erase the earlier violation")
    precondition(policy.completed("required").violation == "unknown-delivery", "repeated completion stays invalid after cleanup")
    precondition(policy.receive("good", required:true))
    policy.entered("good")
    precondition(policy.completed("good").violation == nil)
    precondition(policy.returned("good").reportEntered)
    precondition(policy.receive("good", required:true), "both boundaries release per-delivery state")
    precondition(!policy.receive("good", required:false), "reused pending identifiers cannot replace the obligation")
    precondition(policy.completed("good").violation == "required-report-missing-at-completion")
    precondition(policy.returned("good").violation == "required-report-missing-at-callback-return")
    precondition(policy.receive("optional", required:false))
    precondition(policy.returned("optional").violation == nil)
    precondition(policy.completed("optional").violation == nil)
    precondition(policy.receive("first", required:true) && policy.receive("other", required:true))
    policy.entered("other")
    precondition(!policy.returned("first").reportEntered, "another delivery's actual report never satisfies this push")
    precondition(policy.returned("other").violation == nil)
    precondition(policy.returned("other").violation == "repeated-callback-return")
    precondition(policy.returned("unknown").violation == "unknown-delivery")
    precondition(!policy.receive("", required:true))
    print("passed: required missing/late report, hook-entry observation, completion-before-return, optional omission, repeated/unknown boundaries and overlapping push isolation")
  }
}
'''

PIPELINE = r'''
import Synchronization
public final class PushDelivery: Sendable {
  private let finishes = Mutex(0)
  public init() {}
  public func finish() { finishes.withLock { $0 += 1 } }
  var finishCount: Int { finishes.withLock { $0 } }
}
private enum FixtureFailure: Error { case failed }
@MainActor private final class FixtureClient {
  var incoming: [IncomingCallPayload] = []
  var ended: [CallEndedPayload] = []
  var reportsEnded = 0
  var releaseReport: CheckedContinuation<Void, Never>?
  var failReport = false
  func reportIncomingConversation(_ payload: IncomingCallPayload, source: IncomingReportSource) async throws -> UUID {
    incoming.append(payload)
    await withCheckedContinuation { releaseReport = $0 }
    if failReport { throw FixtureFailure.failed }
    return UUID()
  }
  func receiveCallEnded(_ payload: CallEndedPayload) { ended.append(payload) }
  func reportConversation(_ id: UUID, report: ConversationReport) throws { reportsEnded += 1 }
}
@MainActor private final class PushService {
  let client: FixtureClient
  init(_ client: FixtureClient) { self.client = client }
// EXACT_METHODS
}
@main private struct PipelineTests {
  @MainActor static func wait(_ predicate: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by:.seconds(3))
    while !predicate() { precondition(ContinuousClock.now < deadline); await Task.yield() }
  }
  @MainActor static func main() async {
    do {
      let client=FixtureClient(), ticket=PushDelivery()
      let actual=PushService(client)
      await Task.detached {
        let caller=NSMutableDictionary(dictionary:["id":"original"])
        let body: [String:Any] = ["eventId":"e", "serverCallId":"s", "caller":caller]
        actual.receiveVoIPPush(["incomingCall":body],mustReport:true,delivery:ticket)
        caller["id"]="mutated-after-callback"
      }.value
      await wait { client.releaseReport != nil }
      precondition(client.incoming.count == 1 && client.incoming[0].caller.id == "original", "payload values are decoded before the detached Task")
      precondition(ticket.finishCount == 0, "completion cannot precede the actual awaited report settlement")
      client.releaseReport?.resume()
      await wait { ticket.finishCount == 1 }
    }
    do {
      let client=FixtureClient(), ticket=PushDelivery()
      let actual=PushService(client)
      await Task.detached { actual.receiveVoIPPush([:],mustReport:false,delivery:ticket) }.value
      precondition(ticket.finishCount == 1 && client.incoming.isEmpty)
    }
    for failed in [false,true] {
      let client=FixtureClient(), ticket=PushDelivery(); client.failReport=failed
      let service=PushService(client)
      await Task.detached { service.receiveVoIPPush([:],mustReport:true,delivery:ticket) }.value
      await wait { client.releaseReport != nil }
      precondition(client.incoming.count == 1 && client.incoming[0].caller.id == "unknown" && ticket.finishCount == 0)
      client.releaseReport?.resume()
      await wait { ticket.finishCount == 1 }
      precondition(client.reportsEnded == (failed ? 0 : 1))
    }
    do {
      let client=FixtureClient(), ticket=PushDelivery()
      let actual=PushService(client)
      await Task.detached {
        actual.receiveVoIPPush(["messageType":"callEnded","callEnded":"{\"eventId\":\"end\",\"serverCallId\":\"s\",\"reason\":\"remoteEnded\"}"],mustReport:false,delivery:ticket)
      }.value
      await wait { ticket.finishCount == 1 }
      precondition(client.ended.count == 1 && client.incoming.isEmpty)
    }
    print("passed: exact off-main receiver synchronous decoding, actual-await completion boundary, optional omission, required fallback, thrown reporting and callEnded handling")
  }
}
'''


def compile_run(out, name, text, paths=()):
    source=out/(name+'.swift'); source.write_text('import Foundation\n'+text)
    binary=out/name
    result=subprocess.run(['xcrun','swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',
                           *map(str, paths),str(source),'-o',str(binary)],capture_output=True,text=True,timeout=60)
    if result.returncode: raise RuntimeError(result.stdout+result.stderr)
    result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=15)
    if result.returncode or not result.stdout.startswith('passed:'): raise RuntimeError(result.stdout+result.stderr)
    return result.stdout.strip()


def native_source_identity():
    scope=['Sources','VERSION','discovery/probe/push_report_entry.swift',
           'discovery/build_push_report_entry.sh','discovery/check_push_report_entry.py',
           'discovery/check_push_delivery.py','discovery/run_scenario.py']
    dirty=subprocess.check_output(['git','status','--porcelain','--untracked-files=all','--',*scope],cwd=ROOT)
    if dirty: raise RuntimeError('Commit all A1 source/fixture inputs before a native measurement')
    names=sorted(filter(None,subprocess.check_output(['git','ls-files','-z','--',*scope],cwd=ROOT).decode().split('\0')))
    required=['discovery/probe/push_report_entry.swift','discovery/build_push_report_entry.sh','discovery/check_push_delivery.py']
    if any(name not in names for name in required): raise RuntimeError('Missing committed A1 measurement inputs')
    digest=hashlib.sha256()
    for name in names: digest.update(name.encode()+b'\0'+(ROOT/name).read_bytes()+b'\0')
    return dict(sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                sourceInputsSHA256=digest.hexdigest(),inputs=names)


def qualify_journal(rows, mode, run_id, pid):
    """Strict normal-rule validator; missing/deferred fixtures must be rejected."""
    def require(condition, reason):
        if not condition: raise ValueError(reason)
    require(mode in ('sdk-required','sdk-duplicate','missing','deferred','optional'),'unsupported A1 case')
    require(type(pid) is int and pid>0 and rows and all(type(r.get('pid')) is int and r['pid']==pid and
            r.get('runID')==run_id and r.get('bundleID')=='dev.iosvoipsdk.pushentry' for r in rows),'mixed native journal identity')
    require([r.get('sequence') for r in rows]==list(range(1,len(rows)+1)) and
            all(type(r.get('sequence')) is int and type(r.get('t_ms')) is int for r in rows) and
            all(a['t_ms']<=b['t_ms'] for a,b in zip(rows,rows[1:])),'invalid native journal sequence')
    count=2 if mode=='sdk-duplicate' else 1
    expected={run_id+'-'+str(i) for i in range(count)}
    received=[r for r in rows if r.get('event')=='push.received']
    require(len(received)==count and {r.get('pushID') for r in received}==expected,'missing or substituted delivery')
    incoming=[r for r in rows if r.get('event')=='report.incoming']
    required=mode!='optional'
    for identifier in expected:
        def event(name):
            found=[r for r in rows if r.get('event')==name and r.get('pushID')==identifier]
            require(len(found)==1,'missing or repeated '+name)
            return found[0]
        received_row=event('push.received'); returned=event('push.callbackReturned'); completed=event('push.completed')
        require(all(r.get('mustReport') is required for r in (received_row,returned,completed)),'required-report policy differs')
        require(received_row['sequence']<min(returned['sequence'],completed['sequence']),'delivery boundaries precede receipt')
        if required:
            require(returned.get('reportEntered') is True,'required report was not entered before callback returned')
            require(completed.get('reportEntered') is True,'required completion preceded report entry')
            report=event('report.incoming'); settled=event('report.completed')
            require(received_row['sequence']<report['sequence']<settled['sequence']<min(returned['sequence'],completed['sequence']),
                    'actual awaited report did not settle before both native boundaries')
        else:
            require(returned.get('reportEntered') is False and completed.get('reportEntered') is False and not incoming,
                    'optional omission unexpectedly reported')
    require(not any(r.get('event')=='diagnostic.pushReportingViolation' for r in rows),'runtime detected a push reporting violation')
    if mode=='sdk-duplicate':
        require(len(incoming)==2 and len({r.get('callUUID') for r in incoming})==1,'duplicate did not preserve UUID and two actual reports')
    elif required: require(len(incoming)==1,'unexpected actual report count')
    return dict(success=True,mode=mode,deliveries=count,reportEntryBeforeReturn=True,settlementBeforeCompletion=required)


def journal_controls():
    def fixture():
        return [dict(event=event,pid=123,runID='host',bundleID='dev.iosvoipsdk.pushentry',sequence=i+1,t_ms=i,
                     pushID='host-0',mustReport=True,reportEntered=True,callUUID='call') for i,event in enumerate([
                     'push.received','report.incoming','report.completed','push.callbackReturned','push.completed'])]
    qualify_journal(fixture(),'sdk-required','host',123)
    controls=[]
    for label, mutate in [
        ('return-before-report',lambda r:r[3].update(reportEntered=False)),
        ('completion-before-entry',lambda r:r[4].update(reportEntered=False)),
        ('missing-report',lambda r:r.__delitem__(1)),
        ('wrong-push',lambda r:r[1].update(pushID='other')),
        ('wrong-process',lambda r:r[2].update(pid=124)),
        ('boolean-pid',lambda r:r[0].update(pid=True)),
        ('float-sequence',lambda r:r[2].update(sequence=3.0)),
        ('clock-reversal',lambda r:r[3].update(t_ms=0)),
        ('missing-completion',lambda r:r.pop()),
    ]:
        changed=copy.deepcopy(fixture());mutate(changed)
        try: qualify_journal(changed,'sdk-required','host',123)
        except ValueError: controls.append(label)
        else: raise AssertionError('native gate accepted '+label)
    return 'passed: native journal positive and '+str(len(controls))+' strict evidence negatives ('+', '.join(controls)+')'


def main():
    engine=(ROOT/'Sources/Engine/RuntimeEngine.swift').read_text()
    service=(ROOT/'Sources/VoIPSDK/PushService.swift').read_text()
    client=(ROOT/'Sources/VoIPSDK/ConversationClient.swift').read_text()
    obligations=braced(engine,'private struct PushReportingObligations {')
    receiver=braced(service,'  public nonisolated func receiveVoIPPush(')
    reporting=braced(service,'  private func report(')
    serializer=braced(client,'final class SerializedIncomingReports {')
    assert 'Task {' not in serializer and 'Task.detached' not in serializer, 'new UUID serializer must not create a child Task'
    assert receiver.count('Task.detached(')==1 and '[AnyHashable: Any]' not in reporting, 'one typed report Task is required'
    hook=(ROOT/'Sources/Interposition/CKPushDelivery.m').read_text()
    assert '@finally' in hook and 'CKSimEmit(@"push.callbackReturned"' in hook, 'runtime must record the actual callback exit'
    with tempfile.TemporaryDirectory(prefix='ios-voip-push-entry-') as temp:
        out=Path(temp)
        results=[journal_controls(),compile_run(out,'policy',obligations+'\n'+POLICY),
                 compile_run(out,'pipeline',PIPELINE.replace('// EXACT_METHODS',receiver+'\n'+reporting),
                             [ROOT/'Sources/VoIPSDK/ConversationModels.swift',ROOT/'Sources/VoIPSDK/PushWire.swift'])]
    files=['Sources/Engine/RuntimeEngine.swift','Sources/Interposition/CKPushDelivery.m',
           'Sources/VoIPSDK/PushService.swift','Sources/VoIPSDK/ConversationClient.swift',str(Path(__file__).relative_to(ROOT))]
    print(json.dumps(dict(success=True,classification='host exact-source policy/pipeline controls; native PushKit entry remains separate',
                         controls=results,sourceSHA256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files}),indent=2))


if __name__=='__main__': main()
