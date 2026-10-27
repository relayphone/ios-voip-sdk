#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d /tmp/ios-voip-push-tests.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  Sources/VoIPSDK/ConversationModels.swift Sources/VoIPSDK/PushWire.swift \
  Sources/VoIPSDK/PushService.swift Sources/VoIPSDK/SimulatorSupport.swift Tests/VoIPSDK/PushTests.swift -o "$TEST_OUTPUT/PushTests"
"$TEST_OUTPUT/PushTests"

python3 Tests/Caller/run.py
