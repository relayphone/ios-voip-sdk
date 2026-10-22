#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d /tmp/ios-voip-projection-tests.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  Sources/VoIPSDK/ConversationClient.swift Tests/VoIPSDK/ProjectionTests.swift \
  -o "$TEST_OUTPUT/ProjectionTests"
"$TEST_OUTPUT/ProjectionTests"
