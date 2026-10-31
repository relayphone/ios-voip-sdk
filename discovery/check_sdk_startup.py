#!/usr/bin/env python3
"""Actual application startup and client selection; platform factories are explicit host facades."""
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
    assert manifest['toolsVersion']['_version'] == '6.4.0'
    assert not manifest.get('traits')
    # CocoaPods IPC evaluates a spec in its own directory. Copy exact source
    # bytes so the isolated Podfile.properties fixture models that install root.
    for name in ['IosVoipSDK.podspec', 'package.json', 'VERSION']:
        shutil.copyfile(ROOT / name, out / name)
    (out / 'Podfile.properties.json').write_text('{}')
    spec = json.loads(run(['pod', 'ipc', 'spec', str(out / 'IosVoipSDK.podspec')], cwd=out).stdout)
    # `pod 'IosVoipSDK'` installs the Expo module and the simulator runtime it depends on.
    subspecs = {subspec['name']: subspec for subspec in spec['subspecs']}
    assert spec['default_subspecs'] == 'ExpoModule'
    assert subspecs['ExpoModule']['dependencies']['IosVoipSDK/SimulatorRuntime'] == []
    for name in ('ExpoModule', 'SimulatorRuntime'):
        assert 'CallKit' not in subspecs[name].get('frameworks', [])

def main():
    inputs = [ROOT / name for name in (
        'Sources/VoIPSDK/VoIPApplication.swift', 'Sources/VoIPSDK/ConversationClient.swift',
        'Sources/VoIPSDK/ConversationModels.swift', 'Sources/VoIPSDK/AudioActivation.swift',
        'Package.swift', 'IosVoipSDK.podspec', 'package.json', 'VERSION',
        'discovery/check_sdk_startup.py')]
    before = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    with tempfile.TemporaryDirectory(prefix='voip-sdk-startup-') as temporary:
        out = Path(temporary)
        check_packaging(out)
        application = (ROOT / 'Sources/VoIPSDK/VoIPApplication.swift').read_text()
        boundary = '#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))'
        assert application.count(boundary) == 1
        (out / 'VoIPApplication.swift').write_text(application.replace(boundary, '#if true', 1))
        client = (ROOT / 'Sources/VoIPSDK/ConversationClient.swift').read_text()
        assert not re.search(r'public\s+(?:static\s+)?(?:var shared|func configure\()', client), 'only Application may publish/create the client'
        configuration = client[client.index('  public struct Configuration:'):client.index('  private static var instance')]
        selection = client[client.index('  private static var instance:'):client.index('  private typealias Record')]
        finish = client[client.index('  func finishLaunch() {'):client.index('  private func configureAudio()')]
        activation = (ROOT / 'Sources/VoIPSDK/AudioActivation.swift').read_text()
        policy = activation[activation.index('public struct AudioActivationPolicy:'):activation.index('enum AudioActivationEvent:')]
        (out / 'Facades.swift').write_text('''import Foundation
''' + policy + '''
@MainActor public protocol MediaAdapter: AnyObject {
  func setSystemAudioAuthorization(_ active: Bool)
}
@MainActor public final class NoMediaAdapter: MediaAdapter {
  public init() {}
  public func setSystemAudioAuthorization(_ active: Bool) {}
}
@MainActor final class RecordingMediaAdapter: MediaAdapter {
  var authorizations: [Bool] = []
  var onAuthorization: (@MainActor (Bool) -> Void)?
  func setSystemAudioAuthorization(_ active: Bool) {
    authorizations.append(active); onAuthorization?(active)
  }
}
@MainActor public final class ConversationClient {
''' + configuration + selection + '''
  static var creations = 0
  static var tracks = 0
  static var onTrack: (@MainActor () -> Void)?
  private let configuration: Configuration
  private let mediaAdapter: any MediaAdapter
  private let audioPolicy: AudioActivationPolicy
  private var launchFinished = false
  private init(configuration: Configuration, mediaAdapter: any MediaAdapter, audioPolicy: AudioActivationPolicy) {
    self.configuration = configuration; self.mediaAdapter = mediaAdapter; self.audioPolicy = audioPolicy
    Self.creations += 1 // Explicit facade for constructing the LCK manager.
  }
  var selectedAdapterForHost: any MediaAdapter { mediaAdapter }
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
  func start() throws(PushRegistrationError) {}
}
''')
        (out / 'Probe.swift').write_text('''import Foundation
@MainActor func configurationAndPublicationProbe() -> Bool {
  do {
    // Invalid first configurations must fail before the manager factory, so a
    // valid start can still retry.
    for (groups, members) in [(0, 2), (2, 0)] {
      do {
        _ = try VoIPApplication.start(configuration: .init(client: .init(
          maximumConversationGroups: groups, maximumConversationsPerGroup: members)))
        return false
      } catch {
        guard case VoIPStartupError.invalidConfiguration = error,
              ConversationClient.creations == 0, VoIPApplication.current == nil else { return false }
      }
    }
    let configuration = VoIPApplication.Configuration(client: .init(supportsVideo: false))
    let adapter = RecordingMediaAdapter()
    var reentered = false
    var authorizationReentered = false
    ConversationClient.onTrack = {
      guard let published = VoIPApplication.current else { return }
      do {
        let repeated = try VoIPApplication.start(configuration: configuration, mediaAdapter: adapter)
        let publishedClient = try ConversationClient.forApplication(configuration: configuration.client, mediaAdapter: adapter)
        reentered = repeated === published && repeated.client === publishedClient &&
          repeated.client === published.client && ConversationClient.creations == 1
      } catch {}
    }
    adapter.onAuthorization = { active in
      guard !active, let published = VoIPApplication.current else { return }
      do {
        let repeated = try VoIPApplication.start(configuration: configuration, mediaAdapter: adapter)
        authorizationReentered = repeated === published && repeated.client === published.client
      } catch {}
    }
    let application = try VoIPApplication.start(configuration: configuration, mediaAdapter: adapter)
    guard reentered, authorizationReentered, application === VoIPApplication.current,
          application.client.selectedAdapterForHost === adapter, adapter.authorizations == [false],
          ConversationClient.creations == 1, ConversationClient.tracks == 1,
          try VoIPApplication.start(configuration: configuration) === application,
          try VoIPApplication.start(configuration: configuration, mediaAdapter: adapter) === application,
          adapter.authorizations == [false] else { return false }
    let conflictingAdapter = RecordingMediaAdapter()
    do {
      _ = try VoIPApplication.start(configuration: configuration, mediaAdapter: conflictingAdapter)
      return false
    } catch {
      guard case VoIPStartupError.alreadyConfigured = error else { return false }
    }
    do {
      _ = try ConversationClient.forApplication(configuration: configuration.client, mediaAdapter: conflictingAdapter)
      return false
    } catch {
      guard case VoIPStartupError.alreadyConfigured = error else { return false }
    }
    do {
      _ = try VoIPApplication.start(configuration: configuration, mediaAdapter: adapter,
        audioPolicy: AudioActivationPolicy(activationTimeout: 12, recoveryTimeout: 6))
      return false
    } catch {
      guard case VoIPStartupError.alreadyConfigured = error else { return false }
    }
    var changedClient = configuration; changedClient.client.supportsVideo.toggle()
    var changedApplication = configuration; changedApplication.simulatorSupport.toggle()
    // Reach the production client guard directly: Application rejects its own
    // mismatched configuration before delegating this particular check.
    do {
      _ = try ConversationClient.forApplication(configuration: changedClient.client)
      return false
    } catch {
      guard case VoIPStartupError.alreadyConfigured = error else { return false }
    }
    for conflict in [changedClient, changedApplication] {
      do { _ = try VoIPApplication.start(configuration: conflict); return false }
      catch {
        guard case VoIPStartupError.alreadyConfigured = error else { return false }
      }
    }
    return ConversationClient.creations == 1 && ConversationClient.tracks == 1 &&
      conflictingAdapter.authorizations.isEmpty && adapter.authorizations == [false]
  } catch { return false }
}
@main struct Driver {
  @MainActor static func main() {
    precondition(configurationAndPublicationProbe(),
      "Actual selection and finishLaunch must validate config and publish before reentrant observation")
    print("passed")
  }
}
''')
        models = (ROOT / 'Sources/VoIPSDK/ConversationModels.swift').read_text()
        selected_models = '\n'.join(re.findall(r'public enum (?:UnhandledActionPolicy|VoIPStartupError|PushRegistrationError)[^{]+\{.*?\}', models, re.S))
        assert selected_models.count('public enum ') == 3
        combined = out / 'Startup.swift'
        combined.write_text('import Foundation\n' + selected_models + '\n' +
                            '\n'.join((out / name).read_text() for name in ('Facades.swift', 'VoIPApplication.swift', 'Probe.swift')))
        binary = out / 'Startup'
        run(['swiftc', '-O', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
             str(combined), '-o', str(binary)])
        assert run([str(binary)]).stdout.strip() == b'passed'
    assert before == {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}, 'sources changed during host qualification'
    print(json.dumps(dict(success=True, sourceSHA256=before, classification='optimized host build of the actual Application, client selection and finishLaunch; LCK observation/construction, simulator configuration and PushKit factories are explicit facades',
                          checks=['actual-forApplication-repeated-same-configuration-is-idempotent',
                                  'actual-forApplication-rejects-invalid-first-configurations-before-manager',
                                  'actual-forApplication-rejects-changed-configuration-before-second-manager',
                                  'actual-Application-rejects-client-and-simulator-configuration-conflicts',
                                  'omitted-repeat-adapter-preserves-selection-and-conflicting-adapter-refuses',
                                  'actual-finishLaunch-reentrant-authorization-sees-published-owner-exactly-once',
                                  'actual-finishLaunch-reentrant-observation-sees-published-application-and-client',
                                  'pod-excludes-callkit'])))

if __name__ == '__main__':
    main()
