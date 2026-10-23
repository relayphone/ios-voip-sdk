#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d /tmp/ios-voip-mute-echo.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
python3 - "$TEST_OUTPUT" <<'PY'
from pathlib import Path
import sys
guard = '#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))'
framework = '@preconcurrency import LiveCommunicationKit'
audio = 'import AVFAudio'
# Compile the entire real client on the host. Only its platform/import boundary
# changes; test facades replace LCK/AVAudioSession, never client/handler policy.
for name in ('ConversationClient.swift', 'IncomingReportTransport.swift'):
    source = Path('Sources/VoIPSDK', name).read_text()
    assert source.count(guard) == source.count(framework) == 1
    source = source.replace(guard, '#if true', 1).replace(framework, '', 1)
    if name == 'ConversationClient.swift':
        assert source.count(audio) == 1
        source = source.replace(audio, '', 1)
    Path(sys.argv[1], name).write_text(source)
PY
xcrun clang -fobjc-arc -fmodules -c Sources/VoIPPlatform/VSProcessSDKOwnership.m \
  -o "$TEST_OUTPUT/VSProcessSDKOwnership.o"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -import-objc-header Sources/VoIPPlatform/include/VSProcessSDKOwnership.h \
  Sources/VoIPSDK/ConversationModels.swift Sources/VoIPSDK/ConversationRecord.swift \
  Sources/VoIPSDK/ConversationHandler.swift Sources/VoIPSDK/IncomingInvitationGate.swift \
  Sources/VoIPSDK/ProcessSDKOwnership.swift \
  Sources/VoIPSDK/IncomingIntake.swift Sources/VoIPSDK/PushWire.swift \
  Sources/VoIPSDK/SimulatorSupport.swift "$TEST_OUTPUT/ConversationClient.swift" \
  "$TEST_OUTPUT/IncomingReportTransport.swift" \
  Tests/VoIPSDK/IncomingCachePlatform.swift Tests/VoIPSDK/MuteEchoTests.swift \
  "$TEST_OUTPUT/VSProcessSDKOwnership.o" \
  -o "$TEST_OUTPUT/MuteEchoTests"
python3 - "$TEST_OUTPUT/MuteEchoTests" <<'PY'
import subprocess,sys
result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=15)
print(result.stdout,end='')
print(result.stderr,file=sys.stderr,end='')
raise SystemExit(result.returncode)
PY
