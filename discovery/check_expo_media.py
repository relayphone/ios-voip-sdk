#!/usr/bin/env python3
"""Host-only controls of the Swift wrapper and ObjC bindings with inert facades."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TEST = ROOT / 'Tests/ExpoMedia'


def queued_adapter_controls(out, sdk):
    target = platform.machine() + '-apple-macos14.0'
    (out / 'module.modulemap').write_text('module VoIPPlatform { header "' +
        str(ROOT / 'Sources/VoIPPlatform/include/VSAudioSessionQueue.h') + '" export * }\n' +
        'module VSMediaInterop { header "' + str(TEST / 'QueuedCallbackBoundary.h') + '" export * }\n')
    headers = [str(TEST / 'Facades'), str(ROOT / 'ExpoMedia/Shared'),
               str(ROOT / 'Sources/VoIPPlatform/include')]
    adapted = []
    for name in ('MediaAdapter.swift', 'AudioSessionConfiguration.swift'):
        source = (ROOT / 'Sources/VoIPSDK' / name).read_text()
        guard = '#if canImport(AVFAudio) && (os(iOS) || os(watchOS))'
        if source.splitlines()[0] != guard: raise RuntimeError('Host platform guard differs: ' + name)
        path = out / name; path.write_text(source.replace(guard, '#if true', 1)); adapted.append(str(path))
    commands = [
        ['xcrun', 'clang', '-isysroot', sdk, '-target', target, '-fobjc-arc', '-fmodules', '-c',
         str(ROOT / 'Sources/VoIPPlatform/VSAudioSessionQueue.m'), '-o', str(out / 'Queue.o')],
        ['xcrun', 'clang', '-isysroot', sdk, '-target', target, '-fobjc-arc', '-fmodules',
         *['-I' + path for path in headers], '-c', str(TEST / 'QueuedCallbackBoundary.m'),
         '-o', str(out / 'Callback.o')],
        ['xcrun', 'swiftc', '-target', target, '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
         '-I', str(out), '-c', '-emit-module', '-module-name', 'AVFAudio',
         str(ROOT / 'Tests/AudioCore/AudioSessionFacade.swift'), '-emit-module-path', str(out / 'AVFAudio.swiftmodule'),
         '-o', str(out / 'AVFAudio.o')],
        ['xcrun', 'swiftc', '-target', target, '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
         '-I', str(out), *[flag for path in headers for flag in ('-Xcc', '-I' + path)],
         *adapted, str(ROOT / 'Sources/VoIPSDK/AudioSessionQueue.swift'),
         str(ROOT / 'Sources/VoIPSDK/ConversationModels.swift'),
         str(ROOT / 'Sources/VoIPSDK/ConversationHandler.swift'),
         str(ROOT / 'ExpoMedia/Shared/QueuedMediaAdapter.swift'), str(TEST / 'QueuedAdapterTests.swift'),
         str(out / 'AVFAudio.o'), str(out / 'Queue.o'), str(out / 'Callback.o'),
         '-framework', 'Foundation', '-o', str(out / 'queued-adapter')],
    ]
    for command in commands:
        built = subprocess.run(command, capture_output=True, text=True, timeout=90)
        if built.returncode: raise RuntimeError('Swift queued adapter compile failed:\n' + built.stdout + built.stderr)
    results = []
    for name in ('phase-order', 'configuration-failure', 'queued-cancellation', 'no-media-slow-configuration'):
        result = subprocess.run([str(out / 'queued-adapter'), name], capture_output=True, text=True, timeout=10)
        if result.returncode or not result.stdout.startswith('passed:') or 'SWIFT TASK CONTINUATION MISUSE' in result.stderr:
            raise RuntimeError(f'Swift queued adapter {name} controls failed (exit {result.returncode}):\n' + result.stdout + result.stderr)
        results.append(result.stdout.strip())
    return dict(success=True, results=results)


def route_selection_controls(parent, sdk):
    """Actual Core → selected Swift adapter → native WebRTC route lock seam."""
    out = parent / 'route'
    out.mkdir()
    target = platform.machine() + '-apple-macos14.0'
    platform_headers = ROOT / 'Sources/VoIPPlatform/include'
    (out / 'module.modulemap').write_text(
        'module VoIPPlatform { header "' + str(platform_headers / 'VSAudioSessionQueue.h') +
        '" header "' + str(platform_headers / 'VSAudioSessionLifecycleObserver.h') + '" export * }\n' +
        'module RouteMediaInterop { header "' + str(TEST / 'RouteNativeBoundary.h') + '" export * }\n')
    headers = [TEST / 'Facades', TEST, ROOT / 'ExpoMedia/Shared',
               ROOT / 'ExpoMedia/WebRTC', platform_headers]
    clang_flags = ['xcrun', 'clang', '-isysroot', sdk, '-target', target,
                   '-fobjc-arc', '-fmodules', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                   *['-I' + str(path) for path in headers]]
    objects = []
    for name, source in [('Queue', ROOT / 'Sources/VoIPPlatform/VSAudioSessionQueue.m'),
                         ('WebRTC', ROOT / 'ExpoMedia/WebRTC/WebRTCMediaBinding.m'),
                         ('Boundary', TEST / 'RouteNativeBoundary.m')]:
        obj = out / (name + '.o')
        built = subprocess.run([*clang_flags, '-c', str(source), '-o', str(obj)],
                               capture_output=True, text=True, timeout=90)
        if built.returncode: raise RuntimeError('Route native boundary compile failed:\n' + built.stdout + built.stderr)
        objects.append(str(obj))
    swift_flags = ['xcrun', 'swiftc', '-target', target, '-swift-version', '6', '-warnings-as-errors',
                   '-parse-as-library', '-I', str(out),
                   *[flag for path in headers for flag in ('-Xcc', '-I' + str(path))]]
    built = subprocess.run([*swift_flags, '-c', '-emit-module', '-module-name', 'AVFAudio',
                            str(TEST / 'RouteSessionFacade.swift'), '-emit-module-path', str(out / 'AVFAudio.swiftmodule'),
                            '-o', str(out / 'AVFAudio.o')], capture_output=True, text=True, timeout=90)
    if built.returncode: raise RuntimeError('Route AV facade compile failed:\n' + built.stdout + built.stderr)
    adapted = []
    for name in ('MediaAdapter.swift', 'AudioSessionConfiguration.swift', 'SystemAudioSession.swift'):
        source = (ROOT / 'Sources/VoIPSDK' / name).read_text()
        guard = '#if canImport(AVFAudio) && (os(iOS) || os(watchOS))'
        if source.splitlines()[0] != guard: raise RuntimeError('Route host platform guard differs: ' + name)
        source = source.replace(guard, '#if true', 1).replace('#if os(iOS)', '#if true')
        path = out / name; path.write_text(source); adapted.append(str(path))
    binary = out / 'RouteSelectionTests'
    built = subprocess.run([*swift_flags, *adapted, str(ROOT / 'Sources/VoIPSDK/AudioSessionQueue.swift'),
                            str(ROOT / 'Sources/VoIPSDK/AudioRoutes.swift'),
                            str(ROOT / 'ExpoMedia/Shared/QueuedMediaAdapter.swift'),
                            str(TEST / 'RouteSelectionTests.swift'), str(out / 'AVFAudio.o'), *objects,
                            '-framework', 'Foundation', '-o', str(binary)], capture_output=True, text=True, timeout=90)
    if built.returncode: raise RuntimeError('Route actual seam compile failed:\n' + built.stdout + built.stderr)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
    if result.returncode or not result.stdout.startswith('passed:') or 'SWIFT TASK CONTINUATION MISUSE' in result.stderr:
        raise RuntimeError('Route actual seam controls failed:\n' + result.stdout + result.stderr)
    return dict(success=True, result=result.stdout.strip())


def main():
    inputs = [ROOT / 'Sources/VoIPPlatform/VSAudioSessionQueue.m',
              ROOT / 'Sources/VoIPPlatform/include/VSAudioSessionQueue.h',
              ROOT / 'ExpoMedia/Shared/VSMediaBinding.h', ROOT / 'ExpoMedia/WebRTC/WebRTCAudioContract.h',
              ROOT / 'ExpoMedia/WebRTC/WebRTCMediaBinding.m',
              ROOT / 'ExpoMedia/LiveKit/LiveKitMediaBinding.m',
              ROOT / 'ExpoMedia/Shared/QueuedMediaAdapter.swift',
              ROOT / 'Sources/VoIPSDK/MediaAdapter.swift', ROOT / 'Sources/VoIPSDK/AudioSessionQueue.swift',
              ROOT / 'Sources/VoIPSDK/AudioSessionConfiguration.swift', ROOT / 'Tests/AudioCore/AudioSessionFacade.swift',
              ROOT / 'Sources/VoIPSDK/SystemAudioSession.swift', ROOT / 'Sources/VoIPSDK/AudioRoutes.swift',
              ROOT / 'Sources/VoIPPlatform/include/VSAudioSessionLifecycleObserver.h',
              *sorted(path for path in TEST.rglob('*') if path.is_file()), Path(__file__)]
    snapshot = lambda: {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    before = snapshot()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    cases = [('livekit', 'ExpoMedia/LiveKit/LiveKitMediaBinding.m', 'LiveKitControls.m'),
             ('webrtc', 'ExpoMedia/WebRTC/WebRTCMediaBinding.m', 'WebRTCControls.m'),
             ('webrtc-absent', 'ExpoMedia/WebRTC/WebRTCMediaBinding.m', 'WebRTCAbsentControls.m')]
    results = {}
    with tempfile.TemporaryDirectory(prefix='ios-voip-expo-media-host-') as temporary:
        out = Path(temporary)
        for name, production, control in cases:
            binary = out / name
            command = ['xcrun', 'clang', '-isysroot', sdk, '-fobjc-arc', '-fmodules', '-Wall', '-Wextra',
                       '-Werror', '-Wno-unused-parameter', '-DNSLog=VSHostMediaLog',
                       '-fmodules-cache-path=' + str(out / 'modules'), '-I' + str(TEST / 'Facades'),
                       '-I' + str(TEST), '-I' + str(ROOT / 'ExpoMedia/Shared'),
                       '-I' + str(ROOT / 'ExpoMedia/WebRTC'),
                       '-I' + str(ROOT / 'Sources/VoIPPlatform/include'),
                       str(ROOT / 'Sources/VoIPPlatform/VSAudioSessionQueue.m'), str(ROOT / production),
                       str(TEST / 'HostSupport.m'), str(TEST / control), '-framework', 'Foundation', '-o', str(binary)]
            built = subprocess.run(command, capture_output=True, text=True, timeout=90)
            if built.returncode: raise RuntimeError(name + ' compile failed:\n' + built.stdout + built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            if result.returncode or not result.stdout.startswith('passed:'):
                raise RuntimeError(name + ' controls failed:\n' + result.stdout + result.stderr)
            if name == 'webrtc-absent':
                symbols = subprocess.check_output(['xcrun', 'nm', '-u', str(binary)], text=True, timeout=20)
                if 'OBJC_CLASS_$_RTCAudioSession' in symbols:
                    raise RuntimeError('optional class must not remain a required link symbol')
            results[name] = dict(success=True, result=result.stdout.strip(),
                                 diagnosticsSHA256=hashlib.sha256(result.stderr.encode()).hexdigest())
        results['swift-phase-wiring'] = queued_adapter_controls(out, sdk)
        results['route-lock-wiring'] = route_selection_controls(out, sdk)
    if before != snapshot():
        raise RuntimeError('media contract inputs changed during host controls')
    print(json.dumps(dict(success=True, classification='host-only public-contract facades; no real media, React Native lifecycle, or activation acceptance',
                          cases=results, sourceFiles=before,
                          temporaryProductsRemoved=True), indent=2))


if __name__ == '__main__':
    main()
