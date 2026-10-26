#!/bin/bash
# Generic iOS compilation only: never selects, boots, signs for or installs on a device.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${FOCUS_BUILD_DIR:-${TMPDIR:-/tmp}/focus-probe-build}
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
mkdir -p "$WORK"
limit 60 xcodegen generate --spec "$HERE/project.yml" --quiet
if limit 600 xcodebuild build-for-testing -project "$HERE/FocusProbe.xcodeproj" -scheme FocusProbe \
  -destination 'generic/platform=iOS' -derivedDataPath "$WORK" CODE_SIGNING_ALLOWED=NO \
  >"$WORK/build.log" 2>&1; then
  echo "Generic iOS unsigned build passed: $WORK"
else
  rg -n 'error:|warning:|BUILD FAILED|TEST BUILD FAILED' "$WORK/build.log" | tail -25
  exit 1
fi
