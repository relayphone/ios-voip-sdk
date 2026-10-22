#!/usr/bin/env python3
"""Compile shared audio consumers against installed Apple SDKs without launching apps."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CORE = sorted((ROOT / 'Sources/VoIPSDK').glob('*.swift'))
ENGINE = sorted((ROOT / 'Sources/Engine').glob('*.swift'))
PLATFORM = [ROOT / 'Sources/VoIPPlatform/VSAudioSessionQueue.m',
            ROOT / 'Sources/VoIPPlatform/VSAudioSessionLifecycleObserver.m']
EXPO = [ROOT / 'ExpoMedia/Shared/ExpoMediaSupport.swift',
        ROOT / 'ExpoMedia/Shared/QueuedMediaAdapter.swift',
        ROOT / 'ExpoMedia/WebRTC/MediaSelection.swift']
INPUTS = sorted(set([*CORE, *ENGINE, *PLATFORM, *EXPO, Path(__file__).resolve(),
                    *sorted((ROOT / 'Sources/VoIPPlatform/include').glob('*.h')),
                    *sorted((ROOT / 'Sources/Interposition').glob('*.h')),
                    ROOT / 'Sources/Interposition/include/CKRuntimeBridge.h',
                    ROOT / 'ExpoMedia/Shared/VSMediaBinding.h']))


def main():
    snapshot = lambda: {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in INPUTS}
    before = snapshot()
    checks = []
    with tempfile.TemporaryDirectory(prefix='ios-voip-audio-compile-') as temporary:
        out = Path(temporary)
        header = out / 'AudioHeaders.h'
        header.write_text('#import "' + str(ROOT / 'Sources/Interposition/CKRuntimeSeam.h') + '"\n'
                          '#import "' + str(ROOT / 'Sources/VoIPPlatform/include/VoIPPlatform.h') + '"\n')
        expo_header = out / 'ExpoAudioHeaders.h'
        expo_header.write_text(header.read_text() + '#import "' + str(ROOT / 'ExpoMedia/Shared/VSMediaBinding.h') + '"\n')
        def run(label, command):
            result = subprocess.run(command, capture_output=True, text=True, timeout=150)
            checks.append(dict(label=label, command=command, exitCode=result.returncode,
                               stdout=result.stdout, stderr=result.stderr))
            if result.returncode:
                raise RuntimeError(label + ':\n' + result.stdout + result.stderr)
        for sdk, target in [('iphoneos', 'arm64-apple-ios17.4'),
                            ('iphonesimulator', 'arm64-apple-ios17.4-simulator'),
                            ('watchsimulator', 'arm64-apple-watchos10.4-simulator')]:
            sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
            for source in PLATFORM:
                run(sdk + '-' + source.stem, ['xcrun', '--sdk', sdk, 'clang', '-fsyntax-only',
                    '-target', target, '-isysroot', sdk_path, '-fobjc-arc', '-fmodules',
                    '-fmodules-cache-path=' + str(out / 'modules'), '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', str(source)])
            command = ['xcrun', '--sdk', sdk, 'swiftc', '-typecheck', '-target', target,
                       '-sdk', sdk_path, '-swift-version', '6', '-warnings-as-errors', '-D', 'DEBUG',
                       '-Xcc', '-DDEBUG=1',
                       '-parse-as-library', '-import-objc-header', str(header)]
            sources = [*ENGINE, *CORE] if sdk == 'iphonesimulator' else CORE
            run(sdk + '-core', command + [str(path) for path in sources])
            if sdk == 'iphoneos':
                command[command.index(str(header))] = str(expo_header)
                run(sdk + '-expo-queued-wrapper', command + ['-I', str(ROOT / 'Sources/VoIPPlatform/include'),
                    *[str(path) for path in [*CORE, *EXPO]]])
        if before != snapshot():
            raise RuntimeError('audio inputs changed during compilation')
    print(json.dumps(dict(success=True, sourceFiles=before, checks=checks,
        classification='Measured: actual SDK compiler checks only; no linking, app build, notification delivery, media or simulator/device acceptance.',
        temporaryProductsRemoved=True), indent=2))


if __name__ == '__main__':
    main()
