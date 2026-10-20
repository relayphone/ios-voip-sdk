#!/bin/bash
# Assertion-based discovery. This still executes the prototype, not the Swift port.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -n "${OUT:-}" ]]; then
  mkdir "$OUT" # Refuse stale output, including an existing empty directory.
else
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/callkit-discovery.XXXXXX")
fi
OUT=$(cd "$OUT" && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/callkit-build.XXXXXX")
UDID=""
LOGGER=""
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
compiler() {
  if [[ -n "${COMPILER_DEVELOPER_DIR:-}" ]]; then
    env DEVELOPER_DIR="$COMPILER_DEVELOPER_DIR" xcrun -sdk iphonesimulator "$@"
  else
    xcrun -sdk iphonesimulator "$@"
  fi
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$LOGGER" ]]; then kill "$LOGGER" 2>/dev/null || true; wait "$LOGGER" 2>/dev/null || true; fi
  if [[ -n "$UDID" ]]; then
    limit 20 xcrun simctl shutdown "$UDID" >> "$OUT/cleanup.log" 2>&1 || true
    if ! limit 20 xcrun simctl delete "$UDID" >> "$OUT/cleanup.log" 2>&1; then
      echo "Failed to delete run-owned simulator $UDID" >&2
      [[ "$status" -ne 0 ]] || status=1
    fi
  fi
  rm -rf "$BUILD"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Evidence: $OUT"
{ sw_vers; xcodebuild -version; uname -m; git rev-parse HEAD; } > "$OUT/environment.txt" 2>&1
if [[ -n "${COMPILER_DEVELOPER_DIR:-}" ]]; then
  echo "compilerDeveloperDir=$COMPILER_DEVELOPER_DIR" >> "$OUT/environment.txt"
  env DEVELOPER_DIR="$COMPILER_DEVELOPER_DIR" xcodebuild -version >> "$OUT/environment.txt"
fi
xcrun simctl list runtimes > "$OUT/runtimes.txt"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("platform")=="iOS" and x["isAvailable"]]; print(sorted(r,key=lambda x:[int(p) for p in x["version"].split(".")])[-1]["identifier"])')
DEVTYPE=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; d=[x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if "iPhone" in x["name"] and "Pro" in x["name"] and "Max" not in x["name"]]; print(d[-1])')
echo "runtime=$RUNTIME devicetype=$DEVTYPE" | tee -a "$OUT/environment.txt"
UDID=$(xcrun simctl create "callkit-probe-$$" "$DEVTYPE" "$RUNTIME")
echo "runOwnedSimulator=$UDID" >> "$OUT/environment.txt"
limit 30 xcrun simctl boot "$UDID"
limit 180 xcrun simctl bootstatus "$UDID" -b > /dev/null

SDK_TARGET="$(uname -m)-apple-ios18.0-simulator"
SDK=$(compiler --show-sdk-path)
SWIFT_DEFS=(-D CKSIM_LEGACY_PUSH_ONLY)
CLANG_DEFS=(-DCKSIM_HAS_VOIP_METADATA=0)
PUSH_API=legacy
if [[ -f "$SDK/System/Library/Frameworks/PushKit.framework/Headers/PKVoIPPushMetadata.h" ]]; then
  SWIFT_DEFS=(-D CKSIM_HAS_VOIP_METADATA)
  CLANG_DEFS=(-DCKSIM_HAS_VOIP_METADATA=1)
  PUSH_API=metadata
fi
echo "sdk=$SDK pushAPI=$PUSH_API" >> "$OUT/environment.txt"
mkdir "$BUILD/Probe.app"
cp probe/Info.plist "$BUILD/Probe.app/"
compiler swiftc -target "$SDK_TARGET" "${SWIFT_DEFS[@]}" -swift-version 5 -parse-as-library -O probe/main.swift -o "$BUILD/Probe.app/Probe" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker probe/probe.entitlements > "$OUT/build.log" 2>&1
codesign -s - --force "$BUILD/Probe.app"
for lib in CKSimRuntime CKSimPush; do
  compiler clang -target "$SDK_TARGET" "${CLANG_DEFS[@]}" -fobjc-arc -dynamiclib -framework Foundation -framework CallKit -framework AVFoundation -framework PushKit \
    -o "$BUILD/$lib.dylib" "spike/$lib.m" >> "$OUT/build.log" 2>&1
  codesign -s - --force "$BUILD/$lib.dylib"
done
limit 60 xcrun simctl install "$UDID" "$BUILD/Probe.app"
limit 20 xcrun simctl privacy "$UDID" grant microphone dev.callkitsim.probe
xcrun simctl spawn "$UDID" log stream --style compact --predicate 'process == "callservicesd" AND (composedMessage CONTAINS "wont be a UI" OR composedMessage CONTAINS "Error setting audio active" OR composedMessage CONTAINS "Failed to open URL" OR composedMessage CONTAINS "disconnect reason")' > "$OUT/callservicesd.log" 2>&1 &
LOGGER=$!
run() {
  local name=$1
  local inherited
  shift
  echo "Starting $name"
  inherited=${SIMCTL_CHILD_DYLD_INSERT_LIBRARIES-$(xcrun simctl spawn "$UDID" launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null || true)}
  local libraries=$inherited
  if [[ "$name" != genuine ]]; then libraries="${inherited:+$inherited:}$LIBS"; fi
  if env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$libraries" \
    SIMCTL_CHILD_CKSIM_ENABLED=0 SIMCTL_CHILD_CKSIM_SHADOW=0 SIMCTL_CHILD_CKSIM_PUSH_AFTER= SIMCTL_CHILD_CKSIM_PUSH_TRIGGER_NOTIFICATION= \
    SIMCTL_CHILD_PROBE_MODE=default SIMCTL_CHILD_PROBE_PUSH_REPORT=report "$@" \
    python3 run_scenario.py --output "$OUT/$name.log" --receipt "$OUT/$name.receipt.json" \
    --terminate-command xcrun simctl terminate "$UDID" dev.callkitsim.probe \
    --launch-command xcrun simctl launch --console-pty --terminate-running-process "$UDID" dev.callkitsim.probe; then
    echo "Completed $name"
  else
    local status=$?
    if ! limit 20 xcrun simctl spawn "$UDID" log show --last 10m --style compact \
      --predicate 'eventMessage CONTAINS "dev.callkitsim.probe"' > "$OUT/$name.system.log" 2>&1; then
      echo "System diagnostic collection failed" >> "$OUT/$name.system.log" || true
    fi
    local container
    container=$(limit 10 xcrun simctl get_app_container "$UDID" dev.callkitsim.probe data 2> "$OUT/$name.container-lookup.log") || container=""
    if [[ -n "$container" && -f "$container/Documents/trace.jsonl" ]]; then
      if ! cp "$container/Documents/trace.jsonl" "$OUT/$name.container.jsonl"; then
        echo "Container trace recovery failed" >> "$OUT/$name.container-lookup.log" || true
      fi
    fi
    return "$status"
  fi
}
LIBS="$BUILD/CKSimRuntime.dylib:$BUILD/CKSimPush.dylib"
run genuine SIMCTL_CHILD_PROBE_TIMEOUT_WAIT=12
run runtime SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_TIMEOUT_WAIT=70
# The fixture deliberately arrives before registration to cover slow cold starts.
run push SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_SHADOW=1 SIMCTL_CHILD_CKSIM_PUSH_AFTER=0 SIMCTL_CHILD_PROBE_MODE=push SIMCTL_CHILD_PROBE_PUSH_REGISTRATION_DELAY=3 SIMCTL_CHILD_PROBE_PUSH_WAIT=12
python3 summarize.py "$OUT" --require-receipts | tee "$OUT/summary.json"
