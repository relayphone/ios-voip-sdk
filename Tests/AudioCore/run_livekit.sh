#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/ios-voip-livekit-tests.XXXXXX")
trap 'rm -rf "$TEST_OUTPUT"' EXIT
python3 - "$TEST_OUTPUT" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1])
(output / 'module.modulemap').write_text('module VoIPPlatform { header "' +
    str(Path('Sources/VoIPPlatform/include/VSAudioSessionQueue.h').resolve()) + '" export * }\n')
for source, guard in [
    ('Sources/VoIPSDK/MediaAdapter.swift', '#if canImport(AVFAudio) && (os(iOS) || os(watchOS))'),
    ('Sources/VoIPSDK/AudioSessionConfiguration.swift', '#if canImport(AVFAudio) && (os(iOS) || os(watchOS))'),
    ('Integrations/LiveKit/LiveKitMediaAdapter.swift', '#if os(iOS)'),
]:
    text = Path(source).read_text()
    if text.splitlines()[0] != guard:
        raise SystemExit('Host platform-guard adaptation no longer matches source')
    # Only expose the exact production bodies on macOS; no implementation substitution.
    (output / Path(source).name).write_text(text.replace(guard, '#if true', 1))
PY
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
  -c Sources/VoIPPlatform/VSAudioSessionQueue.m -o "$TEST_OUTPUT/Queue.o"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -I "$TEST_OUTPUT" -c -emit-module \
  -module-name AVFAudio Tests/AudioCore/AudioSessionFacade.swift \
  -emit-module-path "$TEST_OUTPUT/AVFAudio.swiftmodule" -o "$TEST_OUTPUT/AVFAudio.o"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -I "$TEST_OUTPUT" -c -emit-module \
  -module-name LiveKit Tests/AudioCore/LiveKitFacade.swift \
  -emit-module-path "$TEST_OUTPUT/LiveKit.swiftmodule" -o "$TEST_OUTPUT/LiveKit.o"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -I "$TEST_OUTPUT" -c -emit-module \
  -module-name VoIPSDK "$TEST_OUTPUT/MediaAdapter.swift" Sources/VoIPSDK/AudioSessionQueue.swift \
  "$TEST_OUTPUT/AudioSessionConfiguration.swift" \
  -emit-module-path "$TEST_OUTPUT/VoIPSDK.swiftmodule" -whole-module-optimization -o "$TEST_OUTPUT/VoIPSDK.o"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -I "$TEST_OUTPUT" \
  Sources/VoIPSDK/AudioActivation.swift "$TEST_OUTPUT/LiveKitMediaAdapter.swift" \
  Tests/AudioCore/LiveKitAdapterTests.swift "$TEST_OUTPUT/AVFAudio.o" \
  "$TEST_OUTPUT/LiveKit.o" "$TEST_OUTPUT/VoIPSDK.o" "$TEST_OUTPUT/Queue.o" \
  -framework Foundation -o "$TEST_OUTPUT/LiveKitAdapterTests"
python3 - "$TEST_OUTPUT/LiveKitAdapterTests" <<'PY'
import subprocess, sys
result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=15)
print(result.stdout, end='')
print(result.stderr, file=sys.stderr, end='')
if result.returncode or 'SWIFT TASK CONTINUATION MISUSE' in result.stderr:
    raise SystemExit(result.returncode or 1)
PY
