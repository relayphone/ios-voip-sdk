#!/usr/bin/env python3
"""Host main-stall regression of actual intake/reporting/native wait sources.

The report dependency is a Foundation host facade, never LiveCommunicationKit.
No simulator, PushKit app, APNs or device is used. --out retains a fresh capture;
the default compiles and runs in a TemporaryDirectory that is then removed.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SWIFT_INPUTS = ('IncomingIntake.swift', 'IncomingInvitationGate.swift',
                'ConversationModels.swift', 'PushWire.swift')
SOURCE_INPUTS = [
    'Sources/VoIPSDK/PushService.swift',
    'Sources/VoIPSDK/ConversationClient.swift',
    'Sources/VoIPSDK/IncomingReportTransport.swift',
    *('Sources/VoIPSDK/' + name for name in SWIFT_INPUTS),
    'Sources/VoIPPlatform/VSPushRegistryOwner.m',
    'Sources/VoIPPlatform/VSPushDelivery.m',
    'Sources/VoIPPlatform/include/VSPushRegistryOwner.h',
    'Sources/VoIPPlatform/include/VSPushDelivery.h',
    'Tests/VoIPSDK/run_incoming_delivery.py',
    'Tests/VoIPSDK/IncomingDeliveryHost.h',
    'Tests/VoIPSDK/IncomingDeliveryHost.m.in',
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def braced(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    for index in range(opening + 1, len(text)):
        if text[index] == '{': depth += 1
        elif text[index] == '}': depth -= 1
        if depth == 0: return text[start:index + 1]
    raise ValueError('unterminated production source: ' + marker)


SWIFT_TEMPLATE = r'''
import Foundation

// Host framework facade only. The production transport below remains exact.
// Reaching this async method proves only entry into the fixture dependency.
struct Handle: Sendable, Equatable {
  enum Kind: Sendable, Equatable { case phoneNumber, emailAddress, generic }
  let type: Kind
  let value: String
  let displayName: String?
  init(type: Kind, value: String, displayName: String? = nil) {
    self.type = type; self.value = value; self.displayName = displayName
  }
}
enum Conversation {
  struct Capabilities: OptionSet, Sendable {
    let rawValue: UInt32
    static let pausing = Self(rawValue: 1 << 0)
    static let merging = Self(rawValue: 1 << 1)
    static let unmerging = Self(rawValue: 1 << 2)
    static let playingTones = Self(rawValue: 1 << 3)
    static let video = Self(rawValue: 1 << 4)
  }
  struct Update: Sendable {
    let members: [Handle]
    let capabilities: Capabilities
  }
}

private enum FixtureMetadata {
  static func validate(_ projection: IncomingIntake.Projection, id: UUID) {
    precondition(projection.id == id)
    precondition(projection.payload.eventId == "main-stall-event")
    precondition(projection.payload.serverCallId == "main-stall-server")
    precondition(projection.payload.caller == (try! Caller(handleType: .generic, value: "main-stall-caller", displayName: "main-stall-caller")))
    precondition(!projection.payload.hasVideo)
    precondition(projection.payload.startedAt == nil && projection.payload.metadata == nil)
    precondition(projection.terminal == nil)
  }
}

private final class FixtureReportState: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var id: UUID?
  private var validatedMetadata = false
  private var observedOffMain = false
  func record(_ id: UUID) {
    lock.lock(); defer { lock.unlock() }
    precondition(count == 0, "Only one actual facade report is expected.")
    self.id = id; count += 1
    validatedMetadata = true
    observedOffMain = !Thread.isMainThread
  }
  func snapshot() -> (count: Int, id: UUID?, validatedMetadata: Bool, observedOffMain: Bool) {
    lock.lock(); defer { lock.unlock() }
    return (count, id, validatedMetadata, observedOffMain)
  }
}

final class ConversationManager: @unchecked Sendable {
  private let intake: IncomingIntake
  private let state = FixtureReportState()
  init(intake: IncomingIntake) { self.intake = intake }
  var reportCount: Int { state.snapshot().count }
  var reportedID: UUID? { state.snapshot().id }
  var metadataValidated: Bool { state.snapshot().validatedMetadata }
  var observedOffMain: Bool { state.snapshot().observedOffMain }
  func reportNewIncomingConversation(uuid: UUID, update: Conversation.Update) async throws {
    guard let projection = intake.projection(uuid) else {
      preconditionFailure("Canonical intake metadata must exist before report dependency entry.")
    }
    FixtureMetadata.validate(projection, id: uuid)
    precondition(intake.hasPending(uuid), "The actual report attempt must still be pending at entry.")
    precondition(update.members == [Handle(type: .generic, value: "main-stall-caller", displayName: "main-stall-caller")])
    precondition(update.capabilities == [.pausing, .merging, .unmerging, .playingTones])
    state.record(uuid)
    HostReportEntered()
  }
}

// EXACT_REPORT_ERRORS
// EXACT_TRANSPORT_BODY

@MainActor private final class FixtureClient {
  nonisolated let incomingIntake: IncomingIntake
  nonisolated let incomingTransport: IncomingReportTransport
  nonisolated let manager: ConversationManager
  private(set) var projectionCount = 0
  init() {
    let intake = IncomingIntake()
    let manager = ConversationManager(intake: intake)
    incomingIntake = intake
    incomingTransport = IncomingReportTransport(manager: manager)
    self.manager = manager
  }
  func incomingIntakeDidChange() {
    guard let id = manager.reportedID, let projection = incomingIntake.projection(id) else {
      preconditionFailure("The actor must project the transport's canonical report identity.")
    }
    FixtureMetadata.validate(projection, id: id)
    precondition(!incomingIntake.hasPending(id), "Native settlement must commit before actor projection.")
    projectionCount += 1
  }
}

@MainActor private final class PushService: NSObject, PushReceiver {
  private let client: FixtureClient
  private nonisolated let intake: IncomingIntake
  private nonisolated let transport: IncomingReportTransport
  init(_ client: FixtureClient) {
    self.client = client; intake = client.incomingIntake; transport = client.incomingTransport
    super.init()
  }
  func pushTokenDidUpdate(_ token: Data) {}
  func pushTokenDidInvalidate() {}
// EXACT_RECEIVER
// EXACT_SCHEDULE_PROJECTION
}

@main private struct MainStallRegression {
  @MainActor static func main() async throws {
    let client = FixtureClient(), service = PushService(client)
    HostDrive(service)
    let projectionsAtMainUnblock = client.projectionCount
    let reportsAtMainUnblock = client.manager.reportCount
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while (HostCompletionCount() == 0 || client.projectionCount < 1 || !HostCallbackReturned()) &&
          ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    guard let raw = HostMetricsJSON().data(using: .utf8),
          var result = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
      fatalError("Host atomic metrics are missing.")
    }
    let entered = result["fixtureReportEnteredAtCallbackReturn"] as? Bool == true
    let returnedWhileBlocked = result["returnedDuringMainStall"] as? Bool == true
    let callbackOffMain = result["callbackWasMainThread"] as? Bool == false
    let handshake = result["driveHandshakeSucceeded"] as? Bool == true
    let passed = entered && returnedWhileBlocked && callbackOffMain && handshake && HostCallbackReturned()
    result["classification"] = "host exact production intake, receiver, transport and native delegate wait with framework facade; no LCK, PushKit app or device run"
    result["projectionsAtMainUnblock"] = projectionsAtMainUnblock
    result["reportsAtMainUnblock"] = reportsAtMainUnblock
    result["eventualProjectionCount"] = client.projectionCount
    result["eventualReportCount"] = client.manager.reportCount
    result["intakeMetadataValidatedAtReportEntry"] = client.manager.metadataValidated
    result["fixtureReportDependencyObservedOffMain"] = client.manager.observedOffMain
    result["entryInvariantPassed"] = passed
    result["expectedInvariant"] = "report dependency entered before actual native delegate return while MainActor remains blocked; actor projection follows main unblock"
    let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(bytes + Data([10]))
    guard client.manager.reportCount == 1 && HostCompletionCount() == 1 && client.projectionCount == 1 else { exit(2) }
    guard projectionsAtMainUnblock == 0 && reportsAtMainUnblock == 1 &&
          client.manager.metadataValidated && client.manager.observedOffMain else { exit(3) }
    if !passed { exit(1) }
  }
}
'''


def prepare(out, sources):
    push = sources['Sources/VoIPSDK/PushService.swift'].decode()
    receiver = braced(push, '  public nonisolated func receiveVoIPPush(')
    schedule = braced(push, '  private nonisolated func scheduleProjection(')
    transport = sources['Sources/VoIPSDK/IncomingReportTransport.swift'].decode()
    report_errors = braced(sources['Sources/VoIPSDK/ConversationClient.swift'].decode(),
                          'enum ConversationSystemErrors')
    lines = transport.splitlines(keepends=True)
    require(lines[0].strip() == '#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))' and
            lines[-1].strip() == '#endif', 'unexpected transport platform wrapper')
    imports = ('import Foundation', '@preconcurrency import LiveCommunicationKit')
    require(all(sum(line.strip() == item for line in lines) == 1 for item in imports),
            'unexpected transport imports')
    unwrapped = ''.join(line for line in lines[1:-1] if line.strip() not in imports)
    native = braced(sources['Sources/VoIPPlatform/VSPushRegistryOwner.m'].decode(),
                    '- (void)deliverPayload:(PKPushPayload *)payload mustReport:(BOOL)mustReport')
    native_template = sources['Tests/VoIPSDK/IncomingDeliveryHost.m.in'].decode()
    require(native_template.count('// EXACT_DELIVER_PAYLOAD') == 1, 'missing native extraction seam')
    (out / 'IncomingDeliveryHost.m').write_text(native_template.replace('// EXACT_DELIVER_PAYLOAD', native))
    (out / 'IncomingDeliveryHost.h').write_bytes(sources['Tests/VoIPSDK/IncomingDeliveryHost.h'])
    swift = SWIFT_TEMPLATE.replace('// EXACT_TRANSPORT_BODY', unwrapped)
    swift = swift.replace('// EXACT_REPORT_ERRORS', report_errors)
    swift = swift.replace('// EXACT_RECEIVER', receiver).replace('// EXACT_SCHEDULE_PROJECTION', schedule)
    (out / 'IncomingDelivery.swift').write_text(swift)
    return dict(receiverSHA256=sha(receiver.encode()), scheduleProjectionSHA256=sha(schedule.encode()),
                transportBodySHA256=sha(unwrapped.encode()), reportErrorsSHA256=sha(report_errors.encode()),
                nativeDeliveryMethodSHA256=sha(native.encode()),
                transportRemovedLines=['outer platform #if', 'closing #endif', *imports],
                generatedSwiftSHA256=sha(swift.encode()),
                generatedNativeSHA256=sha((out / 'IncomingDeliveryHost.m').read_bytes()))


def validate_result(result):
    require(isinstance(result, dict), 'missing host result object')
    for key in ('fixtureReportEnteredAtCallbackReturn', 'callbackReturned', 'returnedDuringMainStall',
                'driveHandshakeSucceeded', 'intakeMetadataValidatedAtReportEntry',
                'fixtureReportDependencyObservedOffMain', 'entryInvariantPassed'):
        require(result.get(key) is True, 'host invariant failed: ' + key)
    require(result.get('callbackWasMainThread') is False, 'native callback ran on main')
    for key, expected in [('projectionsAtMainUnblock', 0), ('reportsAtMainUnblock', 1),
                          ('eventualProjectionCount', 1), ('eventualReportCount', 1), ('completionCount', 1)]:
        require(type(result.get(key)) is int and result[key] == expected, 'wrong host cardinality: ' + key)
    for key in ('callbackElapsedSeconds', 'reportEntryElapsedSeconds', 'completionElapsedSeconds'):
        require(type(result.get(key)) in (int, float) and math.isfinite(result[key]) and result[key] > 0,
                'invalid host observation: ' + key)
    require(result['reportEntryElapsedSeconds'] <= result['callbackElapsedSeconds'],
            'report dependency entered after callback return')
    require(type(result.get('mainStallElapsedSeconds')) in (int, float) and
            math.isfinite(result['mainStallElapsedSeconds']) and result['mainStallElapsedSeconds'] >= 2.9,
            'main executor did not remain blocked beyond the native callback wait')
    require(result['reportEntryElapsedSeconds'] <= result['completionElapsedSeconds'],
            'completion preceded the actual report dependency')
    require(result.get('mainStallSeconds') == 3.0, 'host main stall changed')


def run(out):
    receipt = dict(success=False,
        classification='host actual intake, receiver, transport and native wait with reporting facade; no LCK, simulator, APNs or device',
        sourceSHA256={}, extractions={}, result=None, commands=[])
    sources = {}

    def command(label, argv, timeout, retain_failure_result=False):
        started = time.monotonic()
        try:
            completed = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=timeout)
            code, stdout, stderr = completed.returncode, completed.stdout, completed.stderr
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr = 'timeout', error.stdout or b'', error.stderr or b''
        (out / (label + '.stdout')).write_bytes(stdout)
        (out / (label + '.stderr')).write_bytes(stderr)
        receipt['commands'].append(dict(label=label, exitCode=code,
            elapsedSeconds=round(time.monotonic() - started, 6),
            stdoutSHA256=sha(stdout), stderrSHA256=sha(stderr)))
        if code != 0 and not retain_failure_result:
            diagnostic = stderr[-4000:].decode(errors='replace').replace(str(out), '<out>').replace(str(ROOT), '<repo>')
            raise RuntimeError(label + ' failed: ' + str(code) + ('; ' + diagnostic if diagnostic else ''))
        return stdout

    try:
        sources = {name: (ROOT / name).read_bytes() for name in SOURCE_INPUTS}
        receipt['sourceSHA256'] = {name: sha(data) for name, data in sources.items()}
        receipt['extractions'] = prepare(out, sources)
        includes = ROOT / 'Sources/VoIPPlatform/include'
        clang = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-fmodules', '-Wall', '-Wextra',
                 '-Werror', '-Wno-unused-parameter', '-I', str(includes),
                 '-fmodules-cache-path=' + str(out / 'clang-modules')]
        command('native-owner', [*clang, '-c', str(out / 'IncomingDeliveryHost.m'),
                                '-o', str(out / 'native-owner.o')], 60)
        command('native-ticket', [*clang, '-c', str(ROOT / 'Sources/VoIPPlatform/VSPushDelivery.m'),
                                 '-o', str(out / 'native-ticket.o')], 60)
        command('swift-compile', ['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
            '-warnings-as-errors', '-parse-as-library', '-module-cache-path', str(out / 'swift-modules'),
            '-import-objc-header', str(out / 'IncomingDeliveryHost.h'), '-Xcc', '-I' + str(includes),
            *(str(ROOT / 'Sources/VoIPSDK' / name) for name in SWIFT_INPUTS),
            str(out / 'IncomingDelivery.swift'), str(out / 'native-owner.o'), str(out / 'native-ticket.o'),
            '-o', str(out / 'IncomingDelivery')], 90)
        raw = command('main-stall', [str(out / 'IncomingDelivery')], 10, retain_failure_result=True)
        receipt['result'] = json.loads(raw)
        validate_result(receipt['result'])
        require(receipt['commands'][-1]['exitCode'] == 0, 'host scenario exited unsuccessfully')
        require(all((ROOT / name).read_bytes() == data for name, data in sources.items()),
                'source changed during host qualification')
        receipt['success'] = True
    except (OSError, ValueError, RuntimeError) as error:
        receipt['failure'] = str(error)
    finally:
        artifacts = ['IncomingDeliveryHost.h', 'IncomingDeliveryHost.m', 'IncomingDelivery.swift',
                     'native-owner.o', 'native-ticket.o', 'IncomingDelivery']
        artifacts += [label + suffix for label in ('native-owner', 'native-ticket', 'swift-compile', 'main-stall')
                      for suffix in ('.stdout', '.stderr')]
        receipt['artifactSHA256'] = {name: sha((out / name).read_bytes()) for name in artifacts if (out / name).is_file()}
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt['success'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, help='retain results in this fresh, nonexistent directory')
    args = parser.parse_args()
    os.umask(0o077)
    if args.out is not None:
        out = args.out.expanduser().absolute()
        if out.exists() or not out.parent.is_dir():
            parser.error('--out must be nonexistent with an existing parent directory')
        out.mkdir(mode=0o700)
        return run(out)
    with tempfile.TemporaryDirectory(prefix='ios-voip-incoming-delivery-') as directory:
        return run(Path(directory))


if __name__ == '__main__':
    raise SystemExit(main())
