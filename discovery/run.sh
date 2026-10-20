#!/bin/bash
# Discovery run: genuine CallKit versus the injected runtime spike in one simulator.
set -uo pipefail
cd "$(dirname "$0")"
OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT" build/Probe.app
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }

{ sw_vers; xcodebuild -version; uname -m; } > "$OUT/environment.txt" 2>&1
xcrun simctl list runtimes > "$OUT/runtimes.txt"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(sorted(r,key=lambda x:[int(p) for p in x["version"].split(".")])[-1]["identifier"])')
DEVTYPE=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; d=[x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if "iPhone" in x["name"] and "Pro" in x["name"] and "Max" not in x["name"]]; print(d[-1])')
echo "runtime=$RUNTIME devicetype=$DEVTYPE" | tee -a "$OUT/environment.txt"
UDID=$(xcrun simctl create callkit-probe "$DEVTYPE" "$RUNTIME")
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b > /dev/null

SDK_TARGET="$(uname -m)-apple-ios18.0-simulator"
cp probe/Info.plist build/Probe.app/
xcrun -sdk iphonesimulator swiftc -target "$SDK_TARGET" -swift-version 5 -parse-as-library -O probe/main.swift -o build/Probe.app/Probe \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker probe/probe.entitlements 2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }
codesign -s - --force build/Probe.app
for lib in CKSimRuntime CKSimPush; do
  xcrun -sdk iphonesimulator clang -target "$SDK_TARGET" -fobjc-arc -dynamiclib -framework Foundation -framework CallKit -framework AVFoundation -framework PushKit \
    -o build/$lib.dylib spike/$lib.m && codesign -s - --force build/$lib.dylib
done
xcrun simctl install "$UDID" build/Probe.app
xcrun simctl privacy "$UDID" grant microphone dev.callkitsim.probe || true

xcrun simctl spawn "$UDID" log stream --style compact --predicate 'process == "callservicesd" AND (composedMessage CONTAINS "wont be a UI" OR composedMessage CONTAINS "Error setting audio active" OR composedMessage CONTAINS "Failed to open URL" OR composedMessage CONTAINS "disconnect reason")' > "$OUT/callservicesd.log" 2>&1 &
LOGGER=$!

run() { local name=$1; shift; env "$@" perl -e 'alarm shift; exec @ARGV' 200 xcrun simctl launch --console-pty --terminate-running-process "$UDID" dev.callkitsim.probe > "$OUT/$name.log" 2>&1; echo "$name exit=$?"; }
LIBS="$PWD/build/CKSimRuntime.dylib:$PWD/build/CKSimPush.dylib"
run genuine SIMCTL_CHILD_PROBE_TIMEOUT_WAIT=12
run runtime SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$LIBS" SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_TIMEOUT_WAIT=70
run push SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$LIBS" SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_SHADOW=1 SIMCTL_CHILD_CKSIM_PUSH_AFTER=2 SIMCTL_CHILD_PROBE_MODE=push SIMCTL_CHILD_PROBE_PUSH_WAIT=12
kill $LOGGER 2>/dev/null
python3 summarize.py "$OUT" | tee "$OUT/summary.txt"
xcrun simctl delete "$UDID" || true
