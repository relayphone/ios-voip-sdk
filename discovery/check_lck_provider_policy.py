#!/usr/bin/env python3
"""Host controls for the exact image classifier and typed per-API profile policy."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command):
    result = subprocess.run(command, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def main():
    source = (ROOT / 'Sources/Interposition/CKInterposition.m').read_text()
    helpers = re.findall(r'BOOL CKSimDelegateUsesLiveCommunicationKit\(id delegate\) \{\n.*?\n\}', source, re.S)
    assert len(helpers) == 1, 'exactly one production image classifier is required'
    helper = helpers[0]
    engine = (ROOT / 'Sources/Engine/RuntimeEngine.swift').read_text()
    provider_api = re.findall(r'^private enum ProviderAPIKind:.*$', engine, re.M)
    profile_policy = re.findall(r'^private struct FulfilledPostEndUnmutePolicy:.*?^\}', engine, re.M | re.S)
    assert len(provider_api) == len(profile_policy) == 1, 'exactly one production provider API and settlement policy are required'
    policy = '\n'.join([provider_api[0], profile_policy[0]])
    checks = []
    with tempfile.TemporaryDirectory(prefix='cksim-lck-policy-') as temporary:
        out = Path(temporary)
        paths = []
        for framework, classname in [('LiveCommunicationKit', 'CKSimLCKFrameworkFixtureDelegate'),
                                     ('NotLiveCommunicationKit', 'CKSimLookalikeFixtureDelegate')]:
            directory = out / (framework + '.framework')
            directory.mkdir()
            fixture = out / (classname + '.m')
            fixture.write_text('#import <Foundation/Foundation.h>\n@interface ' + classname + ' : NSObject @end\n@implementation ' + classname + ' @end\n')
            binary = directory / 'LiveCommunicationKit'
            run(['xcrun', 'clang', '-fobjc-arc', '-dynamiclib', str(fixture), '-framework', 'Foundation', '-o', str(binary)])
            paths.append(str(binary))
        host = out / 'classifier.m'
        host.write_text('#import <Foundation/Foundation.h>\n#import <objc/runtime.h>\n#import <dlfcn.h>\n' + helper + '''
@interface LiveCommunicationKitNamedApplicationDelegate : NSObject @end
@implementation LiveCommunicationKitNamedApplicationDelegate @end
int main(int argc, const char **argv) { @autoreleasepool {
  if (argc != 3 || !dlopen(argv[1], RTLD_NOW | RTLD_LOCAL) || !dlopen(argv[2], RTLD_NOW | RTLD_LOCAL)) return 1;
  if (CKSimDelegateUsesLiveCommunicationKit(nil) || CKSimDelegateUsesLiveCommunicationKit([NSObject new]) ||
      CKSimDelegateUsesLiveCommunicationKit([LiveCommunicationKitNamedApplicationDelegate new])) return 2;
  if (!CKSimDelegateUsesLiveCommunicationKit([NSClassFromString(@"CKSimLCKFrameworkFixtureDelegate") new])) return 3;
  if (CKSimDelegateUsesLiveCommunicationKit([NSClassFromString(@"CKSimLookalikeFixtureDelegate") new])) return 4;
  puts("passed"); return 0;
}}
''')
        binary = out / 'classifier'
        run(['xcrun', 'clang', '-fobjc-arc', str(host), '-framework', 'Foundation', '-o', str(binary)])
        assert run([str(binary), *paths]).strip() == 'passed'
        checks += ['exact-production-classifier-synthetic-framework-image', 'nil-ordinary-and-name-lookalike-rejected',
                   'framework-directory-lookalike-rejected']
        swift = out / 'policy.swift'
        swift.write_text('import Foundation\n' + policy + '''
private struct Envelope: Decodable { let fulfilledPostEndUnmutePolicy: FulfilledPostEndUnmutePolicy }
let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
private let table = try JSONDecoder().decode(Envelope.self, from: bytes).fulfilledPostEndUnmutePolicy
precondition(table.settlement(for: .callkit) == .timeout)
precondition(table.settlement(for: .livecommunicationkit) == .complete)
print("passed")
''')
        binary = out / 'policy'
        run(['xcrun', 'swiftc', str(swift), '-o', str(binary)])
        assert run([str(binary), str(ROOT / 'Sources/Engine/Resources/ios-27.0.json')]).strip() == 'passed'
        checks += ['exact-production-profile-decoding-and-callkit-timeout-policy', 'lck-terminal-settlement-policy']
    print(json.dumps(dict(success=True, classification='host controls; synthetic framework fixture is not genuine LCK',
                         checks=checks, classifierSHA256=hashlib.sha256(helper.encode()).hexdigest(),
                         policySHA256=hashlib.sha256(policy.encode()).hexdigest()), indent=2))


if __name__ == '__main__':
    main()
