#!/usr/bin/env python3
"""Host-only controls of real ObjC bindings against explicit public API facades."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TEST = ROOT / 'Tests/ExpoMedia'


def main():
    inputs = [ROOT / 'Sources/VoIPPlatform/VSAudioSessionQueue.m',
              ROOT / 'Sources/VoIPPlatform/include/VSAudioSessionQueue.h',
              ROOT / 'ExpoMedia/Shared/VSMediaBinding.h', ROOT / 'ExpoMedia/WebRTC/WebRTCAudioContract.h',
              ROOT / 'ExpoMedia/WebRTC/WebRTCMediaBinding.m', ROOT / 'ExpoMedia/LiveKit/LiveKitMediaBinding.m',
              *sorted(path for path in TEST.rglob('*') if path.is_file()), Path(__file__)]
    snapshot = lambda: {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    before = snapshot()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    cases = [('webrtc', 'ExpoMedia/WebRTC/WebRTCMediaBinding.m', 'WebRTCControls.m'),
             ('webrtc-absent', 'ExpoMedia/WebRTC/WebRTCMediaBinding.m', 'WebRTCAbsentControls.m'),
             ('livekit', 'ExpoMedia/LiveKit/LiveKitMediaBinding.m', 'LiveKitControls.m')]
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
    if before != snapshot():
        raise RuntimeError('media contract inputs changed during host controls')
    print(json.dumps(dict(success=True, classification='host-only public-contract facades; no real media, React Native lifecycle, or activation acceptance',
                          cases=results, sourceFiles=before,
                          temporaryProductsRemoved=True), indent=2))


if __name__ == '__main__':
    main()
