#!/bin/bash
# Actual CallKit APIs against a healthy and deliberately incompatible ABI.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${OUT:-}" ]]; then mkdir "$OUT"; else OUT=$(mktemp -d "${TMPDIR:-/tmp}/callkit-abi.XXXXXX"); fi
OUT=$(cd "$OUT" && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/callkit-abi-build.XXXXXX")
UDID=""
compiler() {
  env DEVELOPER_DIR="${COMPILER_DEVELOPER_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}" xcrun --sdk iphonesimulator "$@"
}
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$UDID" ]]; then
    limit 20 xcrun simctl shutdown "$UDID" >> "$OUT/cleanup.log" 2>&1 || true
    if ! limit 20 xcrun simctl delete "$UDID" >> "$OUT/cleanup.log" 2>&1; then status=1; fi
  fi
  rm -rf "$BUILD"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "ABI evidence: $OUT"
{ sw_vers; xcodebuild -version; git rev-parse HEAD; } > "$OUT/environment.txt"
mkdir "$BUILD/Probe.app"
cp discovery/probe/Info.plist "$BUILD/Probe.app/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.callkitsim.abi' "$BUILD/Probe.app/Info.plist"
python3 - "$BUILD/Probe.app/Info.plist" <<'PYPLIST'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: info=plistlib.load(f)
info['UIApplicationSceneManifest']['UISceneConfigurations']={'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'ABI','UISceneDelegateClassName':'ABIProbeScene'}]}
with open(p,'wb') as f: plistlib.dump(info,f)
PYPLIST
SDK=$(compiler --show-sdk-path)
compiler clang -target "$(uname -m)-apple-ios18.0-simulator" -isysroot "$SDK" -fobjc-arc -fmodules \
  discovery/probe/abi.m -framework UIKit -framework CallKit -framework PushKit -o "$BUILD/Probe.app/Probe" > "$OUT/build.log" 2>&1
codesign -s - --force "$BUILD/Probe.app" >> "$OUT/build.log" 2>&1
env DEVELOPER_DIR="${COMPILER_DEVELOPER_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}" \
  CKSIM_BUILD_ARCHS="$(uname -m)" CKSIM_ABI_TESTING=1 bash scripts/build-runtime.sh "$BUILD/runtime" >> "$OUT/build.log" 2>&1
cp "$BUILD/runtime/build-info.json" "$OUT/build-info.json"
RUNTIME=$(limit 30 xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("platform")=="iOS" and x["isAvailable"]]; print(sorted(r,key=lambda x:[int(p) for p in x["version"].split(".")])[-1]["identifier"])')
UDID=$(limit 30 xcrun simctl create "callkit-abi-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$RUNTIME")
echo "runOwnedSimulator=$UDID runtime=$RUNTIME" >> "$OUT/environment.txt"
limit 60 xcrun simctl boot "$UDID"
limit 180 xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1
limit 120 xcrun simctl install "$UDID" "$BUILD/Probe.app"
RUN_ID=$(uuidgen)
python3 - "$OUT/manifest.json" "$BUILD/runtime/CKSimRuntime.dylib" "$BUILD/Probe.app/Probe" "$RUN_ID" "$UDID" "$RUNTIME" <<'PY'
import hashlib,json,pathlib,subprocess,sys
target,runtime,probe,run,sim,os=sys.argv[1:]
manifest=dict(runID=run,simulatorID=sim,simulatorRuntimeID=os,sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),runtimeSHA256=hashlib.sha256(pathlib.Path(runtime).read_bytes()).hexdigest(),probeSHA256=hashlib.sha256(pathlib.Path(probe).read_bytes()).hexdigest())
pathlib.Path(target).write_text(json.dumps(manifest,indent=2)+'\n')
PY
for scenario in refused-queues missing-provider-init missing-controller-init push-delegate-override push-types-override concrete-override shadow-concrete-override missing-selector kvc-exception kvc-ignored-outgoing kvc-ignored-hasConnected kvc-ignored-onHold kvc-ignored-hasEnded; do
  if [[ -n "${CKSIM_ABI_ONLY:-}" && "$scenario" != "$CKSIM_ABI_ONLY" ]]; then continue; fi
  shadow=0
  if [[ "$scenario" == shadow-concrete-override ]]; then shadow=1; fi
  missing=
  if [[ "$scenario" == missing-selector || "$scenario" == refused-queues ]]; then missing=pendingTransactions; fi
  if [[ "$scenario" == missing-provider-init ]]; then missing=initWithConfiguration:; fi
  if [[ "$scenario" == missing-controller-init ]]; then missing=initWithQueue:; fi
  pushclass=
  if [[ "$scenario" == push-delegate-override ]]; then pushclass=ABIPushDelegateRegistry; fi
  if [[ "$scenario" == push-types-override ]]; then pushclass=ABIPushTypesRegistry; fi
  env SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_SHADOW="$shadow" SIMCTL_CHILD_CKSIM_PROFILE=ios-27.0 \
    SIMCTL_CHILD_CKSIM_RUNTIME_PATH="$BUILD/runtime/CKSimRuntime.dylib" \
    SIMCTL_CHILD_CKSIM_RUN_ID="$RUN_ID" SIMCTL_CHILD_CKSIM_ABI_CASE="$scenario" \
    SIMCTL_CHILD_CKSIM_TEST_ACTION_CLASSES=ABILeafAction,ABISiblingAction \
    SIMCTL_CHILD_CKSIM_TEST_MISSING_SELECTOR="$missing" SIMCTL_CHILD_CKSIM_TEST_PUSH_REGISTRY_CLASS="$pushclass" \
    python3 discovery/run_scenario.py --timeout 200 --output "$OUT/$scenario.log" --receipt "$OUT/$scenario.receipt.json" \
    --run-id "$RUN_ID" --simulator-id "$UDID" --scenario "$scenario" --bundle-id dev.callkitsim.abi \
    --terminate-command xcrun simctl terminate "$UDID" dev.callkitsim.abi \
    --launch-command xcrun simctl launch --console-pty --terminate-running-process "$UDID" dev.callkitsim.abi
done
CHECK_ARGS=()
if [[ -n "${CKSIM_ABI_ONLY:-}" ]]; then CHECK_ARGS+=(--case "$CKSIM_ABI_ONLY"); fi
python3 discovery/abi_conformance.py "$OUT" --runtime "$BUILD/runtime/CKSimRuntime.dylib" \
  --probe "$BUILD/Probe.app/Probe" "${CHECK_ARGS[@]}" | tee "$OUT/summary.json"
