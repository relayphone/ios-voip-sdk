#!/usr/bin/env python3
"""Exercise actual probe startup with inert facades; never build or launch an app."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(command):
    subprocess.run([str(value) for value in command], check=True, timeout=60)


def main():
    fixture = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'Tests/SwiftLiveKit/NativeJourney.swift'
    source = fixture.read_text()
    start = '  private func journey(_ mode: String) async throws {'
    end = '    let eventToken = client.observeEvents'
    assert source.count(start) == source.count(end) == 1, 'Probe startup boundaries changed'
    prefix = source[source.index(start):source.index(end)].replace('private func journey', 'func journey', 1)
    with tempfile.TemporaryDirectory(prefix='voip-swift-startup-') as temporary:
        out = Path(temporary)
        (out / 'Journey.swift').write_text('import Foundation\n@MainActor final class NativeJourney {\n' + prefix + '  }\n}\n')
        header = ROOT / 'Sources/VoIPPlatform/include/VSAudioSessionQueue.h'
        (out / 'module.modulemap').write_text(f'module VoIPPlatform {{ header "{header}" export * }}\n')
        target = platform.machine() + '-apple-macos14.0'
        run(['xcrun', 'clang', '-target', target, '-fobjc-arc', '-fmodules', '-Wall', '-Wextra', '-Werror',
             '-c', ROOT / 'Sources/VoIPPlatform/VSAudioSessionQueue.m', '-o', out / 'Queue.o'])
        run(['swiftc', '-target', target, '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
             '-I', out, ROOT / 'Sources/VoIPSDK/AudioSessionQueue.swift', ROOT / 'Sources/VoIPSDK/AudioActivation.swift',
             out / 'Journey.swift', ROOT / 'Tests/SwiftLiveKit/StartupTests.swift', out / 'Queue.o',
             '-framework', 'Foundation', '-o', out / 'StartupTests'])
        failed = False
        for mode in ('healthy', 'stale-audio'):
            result = subprocess.run([str(out / 'StartupTests'), mode], capture_output=True, text=True, timeout=10)
            print(result.stdout, end='')
            print(result.stderr, file=sys.stderr, end='')
            if result.returncode or not result.stdout.startswith('passed:') or 'SWIFT TASK CONTINUATION MISUSE' in result.stderr:
                failed = True
        if failed:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
