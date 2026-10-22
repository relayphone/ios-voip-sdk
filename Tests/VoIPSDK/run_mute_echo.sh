#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d /tmp/ios-voip-mute-echo.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
python3 - "$TEST_OUTPUT/ConversationClient.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/VoIPSDK/ConversationClient.swift').read_text()
guard = '#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))'
framework = '@preconcurrency import LiveCommunicationKit'
audio = 'import AVFAudio'
assert source.count(guard) == source.count(framework) == source.count(audio) == 1
# Compile the entire real client on the host. Only its platform/import boundary
# changes; test facades replace LCK/AVAudioSession, never client/handler policy.
source = source.replace(guard, '#if true', 1).replace(framework, '', 1).replace(audio, '', 1)
Path(sys.argv[1]).write_text(source)
PY
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  Sources/VoIPSDK/ConversationModels.swift Sources/VoIPSDK/ConversationRecord.swift \
  Sources/VoIPSDK/ConversationHandler.swift Sources/VoIPSDK/IncomingInvitationGate.swift \
  Sources/VoIPSDK/SimulatorSupport.swift "$TEST_OUTPUT/ConversationClient.swift" \
  Tests/VoIPSDK/MuteEchoPlatform.swift Tests/VoIPSDK/MuteEchoTests.swift \
  -o "$TEST_OUTPUT/MuteEchoTests"
python3 - "$TEST_OUTPUT/MuteEchoTests" <<'PY'
import subprocess,sys
result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=15)
print(result.stdout,end='')
print(result.stderr,file=sys.stderr,end='')
raise SystemExit(result.returncode)
PY
