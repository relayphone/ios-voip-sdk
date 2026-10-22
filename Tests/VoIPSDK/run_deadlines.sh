#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d /tmp/ios-voip-deadline-tests.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  Sources/VoIPSDK/ConversationModels.swift Sources/VoIPSDK/ConversationHandler.swift \
  Tests/VoIPSDK/DeadlineTests.swift -o "$TEST_OUTPUT/DeadlineTests"
"$TEST_OUTPUT/DeadlineTests"
