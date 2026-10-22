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


def main():
    inputs = [ROOT / name for name in (
        'Sources/VoIPPlatform/VSProcessSDKOwnership.m',
        'Sources/VoIPPlatform/include/VSProcessSDKOwnership.h',
        'Sources/VoIPSDK/VoIPApplication.swift', 'Sources/VoIPSDK/ConversationClient.swift',
        'Sources/VoIPSDK/ConversationModels.swift', 'Sources/VoIPSDK/ProcessSDKOwnership.swift',
        'discovery/check_sdk_ownership.py')]
    before = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    with tempfile.TemporaryDirectory(prefix='voip-process-ownership-') as temporary:
        out = Path(temporary)
        application = (ROOT / 'Sources/VoIPSDK/VoIPApplication.swift').read_text()
        boundary = '#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))'
        assert application.count(boundary) == 1
        (out / 'VoIPApplication.swift').write_text(application.replace(boundary, '#if true', 1))
        client = (ROOT / 'Sources/VoIPSDK/ConversationClient.swift').read_text()
        assert not re.search(r'public\s+(?:static\s+)?(?:var shared|func configure\()', client), 'only Application may publish/create the client'
        configuration = client[client.index('  public struct Configuration:'):client.index('  private static var instance')]
        selection = client[client.index('  private static var instance:'):client.index('  private typealias Record')]
        finish = client[client.index('  func finishLaunch() {'):client.index('  @discardableResult\n  public func observeState')]
        (out / 'Facades.swift').write_text('''import Foundation
@MainActor public final class ConversationClient {
''' + configuration + selection + '''
  static var creations = 0
  static var tracks = 0
  static var onTrack: (@MainActor () -> Void)?
  private let configuration: Configuration
  private var launchFinished = false
  private init(configuration: Configuration) {
    self.configuration = configuration
    Self.creations += 1 // Explicit facade for constructing the LCK manager.
  }
  private func trackManager() { // Explicit facade for observing LCK state.
    Self.tracks += 1; Self.onTrack?()
  }
''' + finish + '''
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
@MainActor public func configurationAndPublicationProbe() -> Bool {
  do {
    // Invalid first configurations must fail before the manager factory. The
    // process claim remains with this same linked SDK, so valid start can retry.
    for (groups, members) in [(0, 2), (2, 0)] {
      do {
        _ = try VoIPApplication.start(configuration: .init(client: .init(
          maximumConversationGroups: groups, maximumConversationsPerGroup: members)))
        return false
      } catch {
        guard (error as? ConversationClientError) == .invalidConfiguration,
              ConversationClient.creations == 0, VoIPApplication.current == nil else { return false }
      }
    }
    let configuration = VoIPApplication.Configuration(client: .init(supportsVideo: false))
    var reentered = false
    ConversationClient.onTrack = {
      guard let published = VoIPApplication.current else { return }
      do {
        let repeated = try VoIPApplication.start(configuration: configuration)
        let publishedClient = try ConversationClient.forApplication(configuration: configuration.client)
        reentered = repeated === published && repeated.client === publishedClient &&
          repeated.client === published.client && ConversationClient.creations == 1
      } catch {}
    }
    let application = try VoIPApplication.start(configuration: configuration)
    guard reentered, application === VoIPApplication.current,
          ConversationClient.creations == 1, ConversationClient.tracks == 1,
          try VoIPApplication.start(configuration: configuration) === application else { return false }
    var changedClient = configuration; changedClient.client.supportsVideo.toggle()
    var changedApplication = configuration; changedApplication.simulatorSupport.toggle()
    // Reach the production client guard directly: Application rejects its own
    // mismatched configuration before delegating this particular check.
    do {
      _ = try ConversationClient.forApplication(configuration: changedClient.client)
      return false
    } catch {
      guard (error as? ConversationClientError) == .alreadyConfigured else { return false }
    }
    for conflict in [changedClient, changedApplication] {
      do { _ = try VoIPApplication.start(configuration: conflict); return false }
      catch {
        guard (error as? ConversationClientError) == .alreadyConfigured else { return false }
      }
    }
    return ConversationClient.creations == 1 && ConversationClient.tracks == 1
  } catch { return false }
}
public func claimOnly() -> Bool {
  do { try ProcessSDKOwnership.claim(); return true } catch { return false }
}
''')
        gate = ROOT / 'Sources/VoIPPlatform/VSProcessSDKOwnership.m'
        assert gate.is_file(), 'the actual Objective-C process claim must exist'
        header = out / 'Ownership.h'
        header.write_text('#import "' + str(ROOT / 'Sources/VoIPPlatform/include/VSProcessSDKOwnership.h') + '"\n')
        obj = out / 'gate.o'
        run(['clang', '-fobjc-arc', '-fmodules', '-c', str(gate), '-o', str(obj)])
        objects = [str(obj)]
        models = (ROOT / 'Sources/VoIPSDK/ConversationModels.swift').read_text()
        selected_models = '\n'.join(re.findall(r'public enum (?:UnhandledActionPolicy|ConversationClientError)[^{]+\{.*?\}', models, re.S))
        assert selected_models.count('public enum ') == 2
        claim = ROOT / 'Sources/VoIPSDK/ProcessSDKOwnership.swift'
        combined = out / 'SDK.swift'
        combined.write_text('import Foundation\n' + selected_models + '\n' +
                            '\n'.join((out / name).read_text() for name in ('Facades.swift', 'VoIPApplication.swift', 'Probe.swift')) +
                            '\n' + claim.read_text())
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
    if CommandLine.arguments.last == "package-contract" || CommandLine.arguments.last == "pod-contract" {
      let podFirst = CommandLine.arguments.last == "pod-contract"
      precondition(podFirst ? ExpoPodSDK.configurationAndPublicationProbe() : SwiftPackageSDK.configurationAndPublicationProbe(),
        "Actual selection and finishLaunch must validate config and publish before reentrant observation")
      precondition((podFirst ? SwiftPackageSDK.startProbe() : ExpoPodSDK.startProbe()) == "duplicateSDKLinkage")
      precondition(SwiftPackageSDK.managerCreations() + ExpoPodSDK.managerCreations() == 1)
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
        for order in ('package-first', 'pod-first', 'package-contract', 'pod-contract'):
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
    print(json.dumps(dict(success=True, sourceSHA256=before, classification='two real optimized host modules/dylibs; actual Application, client selection, finishLaunch and process claim; LCK observation/construction, simulator configuration and PushKit factories are explicit facades',
                          checks=['package-first-duplicate-refused-before-second-manager', 'pod-first-duplicate-refused-before-second-manager',
                                  'same-objc-helper-present-in-both-images', 'concurrent-claims-preserve-owner', 'static-linker-duplicate-is-already-loud',
                                  'actual-forApplication-repeated-same-configuration-is-idempotent',
                                  'actual-forApplication-rejects-invalid-first-configurations-before-manager',
                                  'actual-forApplication-rejects-changed-configuration-before-second-manager',
                                  'actual-Application-rejects-client-and-simulator-configuration-conflicts',
                                  'actual-finishLaunch-reentrant-observation-sees-published-application-and-client',
                                  'actual-finishLaunch-observes-exactly-once-for-both-linked-module-orders' ])))


if __name__ == '__main__':
    main()
