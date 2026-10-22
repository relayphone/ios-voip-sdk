#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_OUTPUT=$(mktemp -d /tmp/ios-voip-device-diagnostics.XXXXXX)
trap 'rm -rf "$TEST_OUTPUT"' EXIT
CLANG=(xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I Sources/VoIPPlatform)
"${CLANG[@]}" -DSDK_DEVICE_QA=1 -c Sources/VoIPPlatform/VSDeviceQADiagnostics.m -o "$TEST_OUTPUT/on-c.o"
"${CLANG[@]}" -c Sources/VoIPPlatform/VSCompletionOnce.m -o "$TEST_OUTPUT/completion.o"
"${CLANG[@]}" -DSDK_DEVICE_QA=1 -c Tests/DeviceQADiagnostics/CompletionTests.m -o "$TEST_OUTPUT/controls.o"
SOURCES=(Sources/VoIPSDK/ConversationModels.swift Sources/VoIPSDK/ConversationClient.swift Sources/VoIPSDK/SDKDeviceQADiagnostics.swift)
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -D SDK_DEVICE_QA -Xcc -DSDK_DEVICE_QA=1 \
  -import-objc-header Tests/DeviceQADiagnostics/Bridge.h "${SOURCES[@]}" \
  Tests/DeviceQADiagnostics/DiagnosticTests.swift "$TEST_OUTPUT/on-c.o" "$TEST_OUTPUT/completion.o" \
  "$TEST_OUTPUT/controls.o" -o "$TEST_OUTPUT/DiagnosticTests"
"${CLANG[@]}" -c Sources/VoIPPlatform/VSDeviceQADiagnostics.m -o "$TEST_OUTPUT/off-c.o"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -whole-module-optimization -emit-object \
  "${SOURCES[@]}" -o "$TEST_OUTPUT/off-swift.o"
python3 - "$TEST_OUTPUT" <<'PY'
from pathlib import Path
import subprocess, sys
root = Path(sys.argv[1])
for filename in ('off-c.o', 'off-swift.o'):
    symbols = subprocess.run(['xcrun', 'nm', '-gU', str(root / filename)], check=True, capture_output=True, text=True).stdout
    if 'VSDeviceQA' in symbols or 'SDKDeviceQA' in symbols:
        raise SystemExit(f'Device QA diagnostic symbols leaked into {filename}')
for filename, required in (('on-c.o', 'VSDeviceQA'), ('DiagnosticTests', 'SDKDeviceQA')):
    symbols = subprocess.run(['xcrun', 'nm', '-gU', str(root / filename)], check=True, capture_output=True, text=True).stdout
    if required not in symbols:
        raise SystemExit(f'Positive diagnostic symbols missing from {filename}')
result = subprocess.run([str(root / 'DiagnosticTests')], capture_output=True, text=True, timeout=20)
print(result.stdout, end='')
print(result.stderr, file=sys.stderr, end='')
if result.returncode != 0:
    print(f'Diagnostic host executable exited {result.returncode}', file=sys.stderr)
if result.returncode == 0:
    print('{"success":true,"symbolStripping":true}')
raise SystemExit(result.returncode)
PY
