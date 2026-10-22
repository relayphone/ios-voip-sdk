#!/usr/bin/env python3
"""Two actual linked SDK modules; platform factories are explicit host facades."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, timeout=90, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace'))
    return result


def check_packaging(out):
    manifest = json.loads(run(['swift', 'package', 'dump-package'], cwd=ROOT).stdout)
    assert manifest['toolsVersion']['_version'] == '6.1.0'
    assert [trait['name'] for trait in manifest['traits']] == ['ProviderOwnershipDiagnostics']
    targets = {target['name']: target for target in manifest['targets']}
    for name, tools in [('VoIPPlatform', ['c']), ('CKSimRuntimeC', ['c']),
                        ('CKSimRuntime', ['swift']), ('VoIPSDK', ['c', 'swift'])]:
        for tool in tools:
            settings = [setting for setting in targets[name]['settings'] if setting['tool'] == tool and
                        setting['kind'].get('define', {}).get('_0', '').startswith('VSSDK_ENABLE_PROVIDER_DIAGNOSTICS')]
            assert len(settings) == 1 and settings[0]['condition'].get('traits') == ['ProviderOwnershipDiagnostics'], (name, tool)
    # CocoaPods IPC evaluates a spec in its own directory. Copy exact source
    # bytes so the isolated Podfile.properties fixture models that install root.
    for name in ['IosVoipSDK.podspec', 'package.json', 'VERSION']:
        shutil.copyfile(ROOT / name, out / name)
    for enabled in [None, False, True]:
        properties = out / 'Podfile.properties.json'
        properties.write_text(json.dumps({} if enabled is None else {'ios-voip-sdk.providerOwnershipMonitoring': str(enabled).lower()}))
        spec = json.loads(run(['pod', 'ipc', 'spec', str(out / 'IosVoipSDK.podspec')], cwd=out).stdout)
        flags = spec['pod_target_xcconfig']
        assert ('VSSDK_ENABLE_PROVIDER_DIAGNOSTICS' in flags['SWIFT_ACTIVE_COMPILATION_CONDITIONS']) == (enabled is True)
        assert ('VSSDK_ENABLE_PROVIDER_DIAGNOSTICS=1' in flags['GCC_PREPROCESSOR_DEFINITIONS']) == (enabled is True)
        assert 'CallKit' not in spec['frameworks']
    properties.write_text(json.dumps({'ios-voip-sdk.providerOwnershipMonitoring': 'yes'}))
    invalid = subprocess.run(['pod', 'ipc', 'spec', str(out / 'IosVoipSDK.podspec')], cwd=out, capture_output=True, timeout=30)
    assert invalid.returncode != 0 and b'must be true or false' in invalid.stdout + invalid.stderr


def main():
    inputs = [*sorted(ROOT.glob('Sources/VoIPPlatform/*.*')), *sorted(ROOT.glob('Sources/VoIPPlatform/include/*.h')),
              ROOT / 'Sources/VoIPSDK/VoIPApplication.swift', ROOT / 'Sources/VoIPSDK/ConversationClient.swift',
              ROOT / 'Sources/VoIPSDK/ConversationModels.swift', ROOT / 'Sources/VoIPSDK/ProcessSDKOwnership.swift',
              ROOT / 'Package.swift', ROOT / 'IosVoipSDK.podspec', ROOT / 'package.json', ROOT / 'VERSION', Path(__file__)]
    before = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    with tempfile.TemporaryDirectory(prefix='voip-process-ownership-') as temporary:
        out = Path(temporary)
        check_packaging(out)
        application = (ROOT / 'Sources/VoIPSDK/VoIPApplication.swift').read_text()
        boundary = '#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))'
        assert application.count(boundary) == 1
        (out / 'VoIPApplication.swift').write_text(application.replace(boundary, '#if true', 1))
        client = (ROOT / 'Sources/VoIPSDK/ConversationClient.swift').read_text()
        assert not re.search(r'public\s+(?:static\s+)?(?:var shared|func configure\()', client), 'only Application may publish/create the client'
        configuration = client[client.index('  public struct Configuration:'):client.index('  private static var instance')]
        (out / 'Facades.swift').write_text('''import Foundation
@MainActor public final class ConversationClient {
''' + configuration + '''
  static var creations = 0
  static var onFinish: (@MainActor () -> Void)?
  private static var instance: ConversationClient?
  private var launched = false
  static func forApplication(configuration: Configuration) throws -> ConversationClient {
    if let instance { return instance }
    let client = ConversationClient(); creations += 1; instance = client; return client
  }
  func finishLaunch() {
    guard !launched else { return }; launched = true
    Self.onFinish?()
  }
}
@MainActor final class SimulatorSupport {
  static func configure(enabled: Bool) throws {}
}
@MainActor public final class PushService {
  init(client: ConversationClient) {}
  func start() throws {}
}
''')
        (out / 'Probe.swift').write_text('''import Foundation
@MainActor public func startProbe() -> String {
  do { _ = try VoIPApplication.start(); return "started" }
  catch { return String(describing: error) }
}
@MainActor public func managerCreations() -> Int { ConversationClient.creations }
@MainActor public func reentrantStartProbe() -> Bool {
  var reentered = false
  ConversationClient.onFinish = {
    guard let published = VoIPApplication.current else { return }
    do {
      let repeated = try VoIPApplication.start()
      reentered = repeated === published && repeated.client === published.client
    } catch {}
  }
  do {
    let application = try VoIPApplication.start()
    return reentered && application === VoIPApplication.current && ConversationClient.creations == 1
  } catch { return false }
}
public func claimOnly() -> Bool {
  do { try ProcessSDKOwnership.claim(); return true } catch { return false }
}
''')
        gate = ROOT / 'Sources/VoIPPlatform/VSProcessSDKOwnership.m'
        objects = []
        header = out / 'Ownership.h'
        header.write_text('#import <Foundation/Foundation.h>\n')
        if gate.exists():
            header.write_text('#import "' + str(ROOT / 'Sources/VoIPPlatform/include/VSProcessSDKOwnership.h') + '"\n')
            obj = out / 'gate.o'
            run(['clang', '-fobjc-arc', '-fmodules', '-c', str(gate), '-o', str(obj)])
            objects.append(str(obj))
        models = (ROOT / 'Sources/VoIPSDK/ConversationModels.swift').read_text()
        selected_models = '\n'.join(re.findall(r'public enum (?:UnhandledActionPolicy|ConversationClientError)[^{]+\{.*?\}', models, re.S))
        assert selected_models.count('public enum ') == 2
        claim = ROOT / 'Sources/VoIPSDK/ProcessSDKOwnership.swift'
        combined = out / 'SDK.swift'
        combined.write_text('import Foundation\n' + selected_models + '\n' +
                            '\n'.join((out / name).read_text() for name in ('Facades.swift', 'VoIPApplication.swift', 'Probe.swift')) +
                            ('\n' + claim.read_text() if claim.exists() else ''))
        for module in ('SwiftPackageSDK', 'ExpoPodSDK'):
            print('Compiling ' + module, flush=True)
            run(['swiftc', '-O', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                 '-emit-library', '-emit-module', '-module-name', module, '-import-objc-header', str(header),
                 str(combined), *objects, '-emit-module-path', str(out / (module + '.swiftmodule')),
                 '-o', str(out / ('lib' + module + '.dylib'))])
            symbols = run(['nm', '-gU', str(out / ('lib' + module + '.dylib'))]).stdout
            assert b'_OBJC_CLASS_$_VSProcessSDKOwnership' in symbols, 'each image must contain the actual same-named helper'
        driver = out / 'Main.swift'
        driver.write_text('''import Foundation
import SwiftPackageSDK
import ExpoPodSDK
@main struct Driver {
  @MainActor static func main() {
    if CommandLine.arguments.last == "reentrant" {
      precondition(SwiftPackageSDK.reentrantStartProbe(), "A startup callback must see the fully published application and client")
      precondition(ExpoPodSDK.startProbe() == "duplicateSDKLinkage")
      print("passed"); return
    }
    let podFirst = CommandLine.arguments.last == "pod-first"
    let start = podFirst ? ExpoPodSDK.startProbe : SwiftPackageSDK.startProbe
    let duplicate = podFirst ? SwiftPackageSDK.startProbe : ExpoPodSDK.startProbe
    precondition(start() == "started" && start() == "started", "Same linked SDK owner must be idempotent")
    precondition(duplicate() == "duplicateSDKLinkage", "A second linked SDK must fail before constructing its manager")
    precondition(SwiftPackageSDK.managerCreations() + ExpoPodSDK.managerCreations() == 1,
      "The process must construct exactly one manager across both SDK modules")
    DispatchQueue.concurrentPerform(iterations: 200) { _ in
      precondition(podFirst ? ExpoPodSDK.claimOnly() : SwiftPackageSDK.claimOnly(), "The owner must survive concurrent claims")
      precondition(podFirst ? !SwiftPackageSDK.claimOnly() : !ExpoPodSDK.claimOnly(), "Concurrent duplicate claims must refuse")
    }
    print("passed")
  }
}
''')
        binary = out / 'Driver'
        run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library', str(driver),
             '-I', str(out), '-L', str(out), '-lSwiftPackageSDK', '-lExpoPodSDK',
             '-Xlinker', '-rpath', '-Xlinker', str(out), '-o', str(binary)])
        for order in ('package-first', 'pod-first', 'reentrant'):
            assert run([str(binary), order]).stdout.strip() == b'passed'
        # Static-link duplicates can fail before startup; this is already loud
        # and is separate from the dynamic two-SDK error path above.
        source = out / 'static.m'
        source.write_text('int main(void) { return 0; }\n')
        copied = out / 'gate-copy.o'; shutil.copyfile(out / 'gate.o', copied)
        static = subprocess.run(['clang', str(source), str(out / 'gate.o'), str(copied),
                                 '-framework', 'Foundation', '-o', str(out / 'Static')],
                                capture_output=True, timeout=30)
        assert static.returncode != 0 and b'duplicate symbol' in static.stderr, 'static duplicate failure must be an actual linker collision'
    assert before == {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}, 'sources changed during host qualification'
    print(json.dumps(dict(success=True, sourceSHA256=before, classification='two real optimized host modules/dylibs; LCK and PushKit factories are facades',
                          checks=['package-first-duplicate-refused-before-second-manager', 'pod-first-duplicate-refused-before-second-manager',
                                  'same-objc-helper-present-in-both-images', 'concurrent-claims-preserve-owner', 'static-linker-duplicate-is-already-loud',
                                  'reentrant-start-sees-published-application-and-client', 'actual-swiftpm-trait-guards-paired-c-and-swift-flags',
                                  'actual-podspec-default-off-opt-in-on-and-invalid-configuration'])))


if __name__ == '__main__':
    main()
