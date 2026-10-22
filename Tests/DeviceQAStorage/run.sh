#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d /tmp/ios-voip-device-qa-tests.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  discovery/device/DeviceQAStorage.swift Tests/DeviceQAStorage/StorageTests.swift \
  -o "$TEST_OUTPUT/StorageTests"
python3 - "$TEST_OUTPUT/StorageTests" <<'PY'
import subprocess, sys
result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=25)
print(result.stdout, end='')
print(result.stderr, file=sys.stderr, end='')
raise SystemExit(result.returncode)
PY
