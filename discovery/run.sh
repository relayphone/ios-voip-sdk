#!/bin/bash
# Genuine baseline and shipping Swift runtime, through the same application.
set -euo pipefail
cd "$(dirname "$0")"
python3 check_oracles.py
if [[ -z "${CKSIM_ONLY:-}" || "${CKSIM_ONLY:-}" == lck || "${CKSIM_ONLY:-}" == lck-* ]]; then
  python3 check_lck_conformance.py
  python3 check_lck_provider_policy.py
  python3 check_lck_probe_readiness.py
fi
if [[ -n "${OUT:-}" ]]; then
  mkdir "$OUT" # Refuse stale output, including an existing empty directory.
else
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/callkit-discovery.XXXXXX")
fi
OUT=$(cd "$OUT" && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/callkit-build.XXXXXX")
UDID=""
LOGGER=""
RUN_ID=$(uuidgen)
ONLY=${CKSIM_ONLY:-}
case "$ONLY" in ""|report-threading|generations|providers-single|providers-ab|providers-ba|providers-handles|providers-late|providers-drop|providers-inv|providers-recreate|lck|lck-basic|lck-cx-after|lck-lck-after|lck-two-managers) ;; *) echo "Unsupported diagnostic selection" >&2; exit 1;; esac
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
prepare_stage() {
  local phase=$1 budget=$2 started status
  shift 2
  echo "Preparing $phase"
  started=$(date +%s)
  if limit "$budget" "$@" > "$OUT/$phase.prepare.log" 2>&1; then status=0; else status=$?; fi
  printf 'phase=%s budgetSeconds=%s elapsedSeconds=%s exitStatus=%s\n' "$phase" "$budget" "$(( $(date +%s) - started ))" "$status" >> "$OUT/preparation.txt" || true
  return "$status"
}
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
  if ! rm -rf "$BUILD"; then [[ "$status" -ne 0 ]] || status=1; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Evidence: $OUT"
{ sw_vers; xcodebuild -version; uname -m; git rev-parse HEAD; } > "$OUT/environment.txt" 2>&1
if [[ -n "${COMPILER_DEVELOPER_DIR:-}" ]]; then
  limit 30 env DEVELOPER_DIR="$COMPILER_DEVELOPER_DIR" xcodebuild -version > "$OUT/compiler-version.txt"
else
  limit 30 xcodebuild -version > "$OUT/compiler-version.txt"
fi
if [[ -n "${COMPILER_DEVELOPER_DIR:-}" ]]; then
  echo "compilerDeveloperDir=$COMPILER_DEVELOPER_DIR" >> "$OUT/environment.txt"
  cat "$OUT/compiler-version.txt" >> "$OUT/environment.txt"
fi
limit 30 xcrun simctl list runtimes > "$OUT/runtimes.txt"
limit 30 xcrun simctl list runtimes -j > "$OUT/runtimes.json"
RUNTIME=$(python3 - "$OUT/runtimes.json" <<'PYRUNTIME'
import json,sys
from summarize import selected_runtime
print(selected_runtime(json.load(open(sys.argv[1])))['identifier'])
PYRUNTIME
)
DEVTYPE=$(limit 30 xcrun simctl list devicetypes -j | python3 -c 'import json,sys; d=[x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if "iPhone" in x["name"] and "Pro" in x["name"] and "Max" not in x["name"]]; print(d[-1])')
echo "runtime=$RUNTIME devicetype=$DEVTYPE" | tee -a "$OUT/environment.txt"
UDID=$(limit 30 xcrun simctl create "callkit-probe-$$" "$DEVTYPE" "$RUNTIME")
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
# Reuse the exact measured provider inputs. Only exit() is replaced so the
# supervisor owns process termination and can drain a complete receipt.
python3 - "$BUILD/providers.swift" <<'PYPROVIDERS'
from pathlib import Path
import sys
source=Path('../docs/research/callkit-simulator-probe/providers.swift').read_text()
assert source.count('    exit(0)') == 1
completion='controller.request(tx) { err in c.resume(returning: describe(err)) }'
assert source.count(completion) == 1
source=source.replace(completion, '''controller.request(tx) { err in
        Trace.shared.log("request.callback", ["label": label, "result": describe(err)])
        c.resume(returning: describe(err))
      }''')
revival='_ = await ring(b, "inv-B-after-invalidate", number: "+15555550164")'
assert source.count(revival) == 1
source=source.replace(revival, 'Trace.shared.log("revival.requested")\n      ' + revival)
Path(sys.argv[1]).write_text(source.replace('    exit(0)', '    return'))
PYPROVIDERS
python3 - "$BUILD/lck.swift" <<'PYLCK'
from pathlib import Path
import sys
source=Path('../docs/research/callkit-simulator-probe/lck.swift').read_text()
assert source.count('    exit(0)') == 1
observed='  let label: String\n'
changed='    log("conversationChanged", LCKTap.describe(conversation))'
outgoing='  func outgoing(_ m: ConversationManager, _ tag: String) async {'
checkpoint='    await sleep(2); snapshot("\\(tag)-outgoing", m)'
for anchor in (observed, changed, outgoing, checkpoint):
    assert source.count(anchor) == 1, 'measured LCK input changed; review the simulator adapter'
source=source.replace(observed, observed + '  let observedConversationStates = LCKProbeConversationStates()\n')
source=source.replace(changed, changed + '\n    observedConversationStates.record(conversation.uuid, state: "\\(conversation.state)")')
source=source.replace(outgoing, '''  // Simulator-only causal checkpoint. The historical device input is unchanged.
  func waitForOutgoingReadiness(_ id: UUID, _ tag: String) async {
    // The measured later CX tap fulfills start without reporting connection.
    if ProcessInfo.processInfo.environment["PROBE_LCK"] == "cx-after" { return }
    let ready = await LCKProbeReadiness.wait {
      !self.managers.isEmpty && self.managers.count == self.taps.count &&
        zip(self.managers, self.taps).allSatisfy { manager, tap in
          manager.conversations.contains { $0.uuid == id && String(describing: $0.state) == "joined" } &&
            tap.observedConversationStates[id] == "joined"
        } && self.observer.calls.contains { $0.uuid == id && $0.hasConnected && !$0.hasEnded }
    }
    guard ready else {
      Trace.shared.log("error", ["stage": "lck-outgoing-readiness", "label": tag, "livenessLimitSeconds": 10])
      exit(1)
    }
  }
''' + outgoing)
source=source.replace(checkpoint, '    await sleep(2); await waitForOutgoingReadiness(id, tag); snapshot("\\(tag)-outgoing", m)')
Path(sys.argv[1]).write_text(source.replace('    exit(0)', '    return'))
PYLCK
compiler swiftc -target "$SDK_TARGET" "${SWIFT_DEFS[@]}" -D CKSIM_CONFORMANCE -swift-version 5 -parse-as-library -O probe/main.swift probe/generations.swift probe/report_threading.swift probe/lck_readiness.swift "$BUILD/providers.swift" "$BUILD/lck.swift" -o "$BUILD/Probe.app/Probe" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker probe/probe.entitlements > "$OUT/build.log" 2>&1
codesign -s - --force "$BUILD/Probe.app"
env DEVELOPER_DIR="${COMPILER_DEVELOPER_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}" \
  bash ../scripts/build-runtime.sh "$BUILD/runtime" >> "$OUT/build.log" 2>&1
python3 - "$OUT/manifest.json" "$RUN_ID" "$UDID" "$RUNTIME" "$DEVTYPE" "$BUILD/Probe.app/Probe" "$BUILD/runtime" <<'PYMANIFEST'
import hashlib,json,pathlib,subprocess,sys
from summarize import environment_metadata
p,run,sim,runtime,device,probe,package=sys.argv[1:]
root=pathlib.Path(package)
info=json.loads((root/'build-info.json').read_text())
manifest=dict(schemaVersion=1,runID=run,simulatorID=sim,simulatorRuntimeID=runtime,deviceTypeID=device,profileID='ios-27.0',
 sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),runtimeVersion=info['version'],
 probeSHA256=hashlib.sha256(pathlib.Path(probe).read_bytes()).hexdigest(),
 runtimeSHA256=hashlib.sha256((root/'CKSimRuntime.dylib').read_bytes()).hexdigest(),
 profileSHA256=hashlib.sha256((root/'profiles/ios-27.0.json').read_bytes()).hexdigest())
manifest.update(environment_metadata(pathlib.Path(p).parent,runtime))
pathlib.Path(p).write_text(json.dumps(manifest,indent=2)+'\n')
PYMANIFEST
cp -R "$BUILD/runtime" "$OUT/runtime-dist"
prepare_stage app-install 180 xcrun simctl install "$UDID" "$BUILD/Probe.app"
prepare_stage permissions 60 xcrun simctl privacy "$UDID" grant microphone dev.callkitsim.probe
xcrun simctl spawn "$UDID" log stream --style compact --predicate 'process == "callservicesd" AND (composedMessage CONTAINS "wont be a UI" OR composedMessage CONTAINS "Error setting audio active" OR composedMessage CONTAINS "Failed to open URL" OR composedMessage CONTAINS "disconnect reason")' > "$OUT/callservicesd.log" 2>&1 &
LOGGER=$!
run() {
  local name=$1
  local inherited
  shift
  if [[ -n "${ONLY:-}" && "$name" != "${ONLY:-}" ]]; then
    if [[ "$ONLY" != lck || "$name" != lck-* ]]; then return 0; fi
  fi
  echo "Starting $name"
  inherited=${SIMCTL_CHILD_DYLD_INSERT_LIBRARIES-$(limit 20 xcrun simctl spawn "$UDID" launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null || true)}
  local libraries=$inherited
  if [[ "$name" != genuine ]]; then libraries="${inherited:+$inherited:}$LIBS"; fi
  if env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$libraries" \
    SIMCTL_CHILD_CKSIM_ENABLED=0 SIMCTL_CHILD_CKSIM_SHADOW=0 SIMCTL_CHILD_CKSIM_PUSH_AFTER= SIMCTL_CHILD_CKSIM_PUSH_TRIGGER_NOTIFICATION= \
    SIMCTL_CHILD_PROBE_MODE=default SIMCTL_CHILD_PROBE_PUSH_REPORT=report SIMCTL_CHILD_PROBE_WAIT_FOR_TEARDOWN=0 "$@" \
    SIMCTL_CHILD_CKSIM_RUN_ID="$RUN_ID" \
    python3 run_scenario.py --console-launcher-stop --output "$OUT/$name.log" --receipt "$OUT/$name.receipt.json" \
    --run-id "$RUN_ID" --simulator-id "$UDID" --scenario "$name" --bundle-id dev.callkitsim.probe \
    --terminate-command xcrun simctl terminate "$UDID" dev.callkitsim.probe \
    --launch-command xcrun simctl launch --console-pty --terminate-running-process "$UDID" dev.callkitsim.probe; then
    local container
    container=$(limit 20 xcrun simctl get_app_container "$UDID" dev.callkitsim.probe data)
    local journal="$container/Documents/.callkit-simulator/$RUN_ID/events.jsonl"
    if [[ "$name" != genuine ]]; then
      cp "$journal" "$OUT/$name.engine.jsonl"
      python3 - "$OUT/$name.receipt.json" "$OUT/$name.engine.jsonl" <<'PY'
import hashlib,json,sys,pathlib
p=pathlib.Path(sys.argv[1]);r=json.loads(p.read_text());r['engineSHA256']=hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest();p.write_text(json.dumps(r,indent=2)+'\n')
PY
    fi
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
LIBS="$BUILD/runtime/CKSimRuntime.dylib"
run report-threading SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_MODE=report-threading
if [[ -z "$ONLY" || "$ONLY" == report-threading ]]; then
  limit 20 python3 report_threading_conformance.py "$OUT" | tee "$OUT/report-threading-conformance.json"
  limit 20 python3 check_image_identity.py --capture "$OUT" | tee "$OUT/image-identity-checks.json"
  if [[ "$ONLY" == report-threading ]]; then exit; fi
fi
for case in basic cx-after lck-after two-managers; do
  run "lck-$case" SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_MODE=lck SIMCTL_CHILD_PROBE_LCK="$case"
done
if [[ -z "$ONLY" || "$ONLY" == lck || "$ONLY" == lck-* ]]; then
  lck_args=("$OUT")
  if [[ -n "$ONLY" && "$ONLY" != lck ]]; then lck_args+=(--case "${ONLY#lck-}"); fi
  limit 20 python3 lck_conformance.py "${lck_args[@]}" | tee "$OUT/lck-conformance.json"
  if [[ -n "$ONLY" ]]; then exit; fi
fi
run genuine SIMCTL_CHILD_PROBE_TIMEOUT_WAIT=12 SIMCTL_CHILD_PROBE_WAIT_FOR_TEARDOWN=1
run runtime SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_TIMEOUT_WAIT=70
# The fixture deliberately arrives before registration to cover slow cold starts.
run push SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_SHADOW=1 SIMCTL_CHILD_CKSIM_PUSH_AFTER=0 SIMCTL_CHILD_CKSIM_PUSH_MUST_REPORT=1 SIMCTL_CHILD_PROBE_MODE=push SIMCTL_CHILD_PROBE_PUSH_REGISTRATION_DELAY=3 SIMCTL_CHILD_PROBE_PUSH_WAIT=12
if [[ -z "$ONLY" ]]; then python3 summarize.py "$OUT" --require-receipts | tee "$OUT/summary.json"; fi
for case in single ab ba handles late drop inv recreate; do
  run "providers-$case" SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_MODE=providers SIMCTL_CHILD_PROBE_PROVIDERS="$case"
done
if [[ -n "$ONLY" ]]; then
  if [[ "$ONLY" == generations ]]; then
    run generations SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_MODE=generations
    python3 generations_conformance.py "$OUT"
    exit
  fi
  python3 - "$OUT" "${ONLY#providers-}" <<'PYONE'
import json,sys
from pathlib import Path
from conformance import providers
print(json.dumps(providers(Path(sys.argv[1]),sys.argv[2]),indent=2))
PYONE
  exit
fi
python3 conformance.py "$OUT" | tee "$OUT/conformance.json"
python3 check_conformance.py "$OUT" | tee "$OUT/conformance-checks.json"
python3 cli_conformance.py "$UDID" "$BUILD/runtime" "$OUT" | tee "$OUT/cli-conformance.json"
run semantics-answer-rules SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_MODE=semantics SIMCTL_CHILD_PROBE_SECTIONS=waiting2,starts,remote
run semantics-failures SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_MODE=semantics SIMCTL_CHILD_PROBE_SECTIONS=failures
python3 semantics_conformance.py "$OUT" | tee "$OUT/semantics-conformance.json"
run generations SIMCTL_CHILD_CKSIM_ENABLED=1 SIMCTL_CHILD_CKSIM_LATENCY=device SIMCTL_CHILD_PROBE_MODE=generations
python3 generations_conformance.py "$OUT" | tee "$OUT/generations-conformance.json"
python3 check_shipping_controls.py "$OUT" | tee "$OUT/shipping-controls.json"
