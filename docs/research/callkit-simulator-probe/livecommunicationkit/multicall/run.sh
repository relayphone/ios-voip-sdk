#!/bin/bash
# run.sh build | smoke | row NAME | all | clean
# Builds the LiveCommunicationKit multi-call probe with its UI test, then runs rows on the iPhone 13
# only. Each row: arm Documents/lck-multi.json, reset the trace, run MultiCallUITests/testRow with the
# row's UI steps, wait for the probe's DONE status, fetch the trace to <row>.jsonl, disarm.
set -uo pipefail
U=${FOCUS_DEVICE:?Set FOCUS_DEVICE to the target device identifier}
HERE=$(cd "$(dirname "$0")" && pwd)
PROBE=$(cd "$HERE/../.." && pwd)
REPO=$(cd "$PROBE/../../.." && pwd)
WORK=${WORK:-${TMPDIR:-/tmp}/lckmulti-work}
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
copy_to() { limit 60 xcrun devicectl device copy to --device $U --domain-type appDataContainer \
  --domain-identifier dev.callkitsim.probe --source "$1" --destination "Documents/$2" >/dev/null 2>&1; }
copy_from() { limit 60 xcrun devicectl device copy from --device $U --domain-type appDataContainer \
  --domain-identifier dev.callkitsim.probe --source "Documents/$1" --destination "$2" >/dev/null 2>&1; }

assemble() {
  rm -rf "$WORK/src"; mkdir -p "$WORK/src" "$WORK/logs"
  cp "$PROBE"/{main,providers,lck,lckpush,lckmulti}.swift "$PROBE/Info.plist" "$HERE/MultiCallUITests.swift" "$HERE/project.yml" "$WORK/src/"
  cp "$REPO/discovery/device/Probe.entitlements" "$WORK/src/"
  : > "$WORK/empty.jsonl"; echo '{}' > "$WORK/off.json"
  (cd "$WORK/src" && xcodegen generate --quiet)
}

build() {
  assemble
  limit 1200 xcodebuild build-for-testing -project "$WORK/src/CallKitProbe.xcodeproj" -scheme Probe \
    -destination "id=$U" -derivedDataPath "$WORK/dd" -allowProvisioningUpdates >"$WORK/logs/build.log" 2>&1
  local status=$?; tail -3 "$WORK/logs/build.log"; return $status
}

xctestrun() { ls "$WORK"/dd/Build/Products/*.xctestrun | head -1; }

run_row() {
  local name=$1 cfg="$WORK/cfg-$1.json" ui armed
  python3 "$HERE/rows.py" "$name" config > "$cfg"
  ui=$(python3 "$HERE/rows.py" "$name" ui)
  armed=$([ "$(cat "$cfg")" != "{}" ] && echo 1 || echo 0)
  copy_to "$cfg" lck-multi.json; copy_to "$WORK/empty.jsonl" trace.jsonl
  echo "== $name ($(date +%H:%M:%S)) ui=$ui"
  TEST_RUNNER_MULTI_ROW="$name" TEST_RUNNER_MULTI_UI="$ui" limit 900 xcodebuild test-without-building \
    -xctestrun "$(xctestrun)" -destination "id=$U" -only-testing:ProbeUITests/MultiCallUITests/testRow \
    >"$WORK/logs/$name.log" 2>&1
  echo "   xcodebuild exit $? ; $(grep -E 'UITRACE .*(finished|not found)' "$WORK/logs/$name.log" | tail -3 | tr '\n' ' ')"
  if [ "$armed" = 1 ]; then
    local deadline=$((SECONDS + 150))
    while [ $SECONDS -lt $deadline ]; do
      copy_from trace.jsonl "$WORK/poll.jsonl" && grep -q '"status":"DONE' "$WORK/poll.jsonl" && break
      sleep 5
    done
    copy_from trace.jsonl "$HERE/$name.jsonl"
    grep -q '"status":"DONE' "$HERE/$name.jsonl" && echo "   trace DONE ($(wc -l < "$HERE/$name.jsonl") rows)" || echo "   trace NOT DONE"
  fi
  copy_to "$WORK/off.json" lck-multi.json
}

case "${1:-}" in
  build) build ;;
  smoke)
    # An empty script keeps the probe's default CallKit scenario from running (it would place calls).
    echo '{"row":"smoke","steps":[]}' > "$WORK/smoke.json"; copy_to "$WORK/smoke.json" lck-multi.json
    TEST_RUNNER_MULTI_ROW=smoke TEST_RUNNER_MULTI_UI='["?dismiss:3","launch","wait:3","dump:smoke"]' limit 600 xcodebuild test-without-building \
      -xctestrun "$(xctestrun)" -destination "id=$U" -only-testing:ProbeUITests/MultiCallUITests/testRow >"$WORK/logs/smoke.log" 2>&1
    echo "smoke exit $?"; grep -E "UITRACE|TEST (SUCCEEDED|FAILED)|\*\* TEST" "$WORK/logs/smoke.log" | tail -12 ;;
  row) run_row "$2" ;;
  all) for r in $(python3 "$HERE/rows.py" list); do run_row "$r"; done ;;
  clean) copy_to "$WORK/off.json" lck-multi.json; rm -rf "$WORK/dd" ;;
  *) echo "usage: run.sh build | smoke | row NAME | all | clean" >&2; exit 2 ;;
esac
