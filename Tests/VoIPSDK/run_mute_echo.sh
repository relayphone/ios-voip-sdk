#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d /tmp/ios-voip-mute-echo.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
python3 - "$TEST_OUTPUT" <<'PY'
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
out = Path(sys.argv[1])
(out / 'ConversationClient.swift').write_text(source)
adapter = Path('Sources/VoIPSDK/MediaAdapter.swift').read_text()
adapter_guard = '#if canImport(AVFAudio) && (os(iOS) || os(watchOS))'
assert adapter.count(adapter_guard) == adapter.count(audio) == 1
(out / 'MediaAdapter.swift').write_text(adapter.replace(adapter_guard, '#if true', 1).replace(audio, '', 1))
PY
python3 - "$TEST_OUTPUT" <<'PYTHON'
import os,signal,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1])
root=Path.cwd()
def bounded(command, seconds):
    process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:
        stdout,stderr=process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL)
        stdout,stderr=process.communicate()
        sys.stdout.buffer.write(stdout); sys.stderr.buffer.write(stderr)
        raise SystemExit('Owned host check exceeded its bounded compiler/runtime budget')
    sys.stdout.buffer.write(stdout); sys.stderr.buffer.write(stderr)
    if process.returncode: raise SystemExit(process.returncode)
for name in ('MuteEchoTests','ClientContractTests'):
    bounded(['swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',
      *[str(root/'Sources/VoIPSDK'/file) for file in ('ConversationModels.swift','ConversationRecord.swift',
        'ConversationHandler.swift','IncomingInvitationGate.swift','PushWire.swift','SimulatorSupport.swift',
        'AudioActivation.swift','AudioRoutes.swift','AudioSessionQueue.swift')],
      str(out/'ConversationClient.swift'),str(out/'MediaAdapter.swift'),
      str(root/'Tests/VoIPSDK/MuteEchoPlatform.swift'),str(root/'Tests/VoIPSDK'/ (name+'.swift')),
      '-o',str(out/name)],90)
    bounded([str(out/name)],15)
PYTHON
