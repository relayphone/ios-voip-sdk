#!/bin/bash
# Exercise prebuilt M0 products on exactly one fresh, run-owned simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SDK_M0_APP:?provide the Release Expo .app with bundled JavaScript}"
: "${SDK_M0_BOOTSTRAP_APP:?provide the source SDKBootstrap.app}"
: "${SDK_M0_DEVICE_PROBE:?provide the linked SDKDeviceProbe executable}"
: "${SDK_M0_SPM_DEVICE_DIR:?provide SwiftPM device DerivedData}"
: "${SDK_M0_BUILD_RECEIPT:?provide the source-bound native build receipt}"
: "${SDK_M0_BUILD_LOGS:?provide the nonempty native build logs directory}"
SDK_M1_PART=${SDK_M1_PART:-all}
case "$SDK_M1_PART" in all|journeys|contracts|push-entry) ;; *) echo 'Unknown M1 journey part' >&2; exit 2;; esac
if [[ "${SDK_M1_ACCEPTANCE:-0}" == 1 ]]; then
  : "${SDK_M1_CONTRACT_BUILD:?provide the source-bound Debug M1 contract build}"
  : "${SDK_PUSH_ENTRY_BUILD:?provide the source-bound Debug A0/A1 push-entry build}"
fi
if [[ "${SDK_SYSTEM_ACCEPTANCE:-0}" == 1 ]]; then
  : "${SDK_SYSTEM_CONTROL_PACKAGE:?provide a source-bound cksim package for external controls}"
fi
if [[ -n "${OUT:-}" ]]; then mkdir "$OUT"; else OUT=$(mktemp -d "${TMPDIR:-/tmp}/sdk-m0.XXXXXX"); fi
OUT=$(cd "$OUT" && pwd)
UDID=""
INHERITED_DYLD=""
INHERITED_DYLD_SIMULATOR=""
INHERITED_DYLD_REDACTIONS=""
RUN_ID=$(uuidgen)
SIM_STATE="$OUT/simulator-state.json"
export SIM_FAILURE_MARKER="$SIM_STATE.failure"
PRODUCT_CHECK=preflight
source scripts/sim/sim.sh
limit() {
  local seconds=$1 status=0
  shift
  printf 'SDK infrastructure start (%ss):' "$seconds" >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  if declare -F sim_limit >/dev/null; then
    sim_limit "$seconds" "$@" || status=$?
  else
    python3 scripts/sim/sim.py call '' "$seconds" "$@" || status=$?
  fi
  printf 'SDK infrastructure exit: %s\n' "$status" >&2
  return "$status"
}
cleanup_simulator() {
  # The persisted name also owns a device whose create call never returned.
  sim_cleanup --timeout 60 || { : > "$SIM_STATE.failure"; return 1; }
  UDID=""
}
read_launch_environment() {
  local query_status=0
  if [[ -n "${SIMCTL_CHILD_DYLD_INSERT_LIBRARIES+x}" ]]; then
    INHERITED_DYLD=$SIMCTL_CHILD_DYLD_INSERT_LIBRARIES
  else
    SDK_ENV_QUERY_STARTED=$SECONDS
    printf 'Read inherited DYLD_INSERT_LIBRARIES with a 180-second cold-start infrastructure budget.\n' >> "$OUT/launch-environment-query.log" || return 1
    printf 'Simulator: %s\n' "$UDID" >> "$OUT/launch-environment-query.log" || return 1
    INHERITED_DYLD=$(SIM_ACCEPTED_STATUS=1 SIMCTL_CHILD_DYLD_INSERT_LIBRARIES='' limit 180 xcrun simctl spawn "$UDID" launchctl getenv DYLD_INSERT_LIBRARIES 2>> "$OUT/launch-environment-query.log") || query_status=$?
    printf 'Query exit code: %s; elapsed seconds: %s\n' "$query_status" "$((SECONDS - SDK_ENV_QUERY_STARTED))" >> "$OUT/launch-environment-query.log" || return 1
  fi
  # Keep all observed external paths available to failure cleanup redaction.
  INHERITED_DYLD_REDACTIONS="${INHERITED_DYLD_REDACTIONS:-}${INHERITED_DYLD_REDACTIONS:+:}$INHERITED_DYLD"
  [[ "$query_status" -le 1 ]] || {
    printf 'Cannot read inherited launch environment (exit %s); see %s/launch-environment-query.log\n' "$query_status" "$OUT" >&2
    return 1
  }
  SDK_M0_EXTERNAL_DYLD="$INHERITED_DYLD" python3 - <<'PY' || return 1
import os,pathlib
entries=os.environ['SDK_M0_EXTERNAL_DYLD'].split(':')
assert not any(pathlib.Path(p).name in ('CKSimRuntime.dylib','CKSimLoader.dylib') for p in entries if p), \
    'Plain M0 acceptance refuses external SDK runtime injection'
PY
  INHERITED_DYLD_SIMULATOR=$UDID
}
simulator_changed() {
  OWNED_SIMULATOR=$1
  # A fresh-device install retry also changes the final evidence identity.
  python3 - "$OUT/environment.json" "$1" <<'PY' || return 1
import json,pathlib,sys
path=pathlib.Path(sys.argv[1])
if path.exists():
    row=json.loads(path.read_text()); row['simulatorID']=sys.argv[2]
    path.write_text(json.dumps(row,indent=2)+'\n')
PY
  if [[ ! -f "$SIM_STATE.failure" && -n "${INHERITED_DYLD_SIMULATOR:-}" &&
        -z "${SIMCTL_CHILD_DYLD_INSERT_LIBRARIES+x}" &&
        "$INHERITED_DYLD_SIMULATOR" != "$1" ]]; then
    read_launch_environment || return 1
  fi
}
redact_external_paths() {
  local libraries=${INHERITED_DYLD_REDACTIONS:-$INHERITED_DYLD}
  [[ -n "$libraries" ]] || return 0
  SDK_M0_EXTERNAL_DYLD="$libraries" python3 - "$OUT" <<'PY'
import hashlib,json,os,pathlib,sys
root=pathlib.Path(sys.argv[1])
paths=[p.encode() for p in os.environ['SDK_M0_EXTERNAL_DYLD'].split(':') if p]
for log in root.rglob('*.log'):
    original=log.read_bytes()
    data=original
    for path in paths: data=data.replace(path,b'<inherited-external-library>')
    if data==original: continue
    log.write_bytes(data)
    receipt=log.with_suffix('.receipt.json')
    if receipt.exists():
        row=json.loads(receipt.read_text())
        row['unredactedTraceSHA256']=row['traceSHA256']
        row['traceSHA256']=hashlib.sha256(data).hexdigest()
        row['externalLibraryPathsRedacted']=True
        receipt.write_text(json.dumps(row,indent=2)+'\n')
PY
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && ! -f "$SIM_STATE.failure" ]]; then
    python3 "$SIM_HELPER" product "$PRODUCT_CHECK" || true
  fi
  cleanup_simulator || status=1
  redact_external_paths || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "SDK M0 evidence: $OUT"
python3 - "$OUT/source-before.json" "$SDK_M0_APP" "$SDK_M0_BOOTSTRAP_APP" "$SDK_M0_DEVICE_PROBE" "$SDK_M0_SPM_DEVICE_DIR" "$SDK_M0_BUILD_RECEIPT" "$SDK_M0_BUILD_LOGS" <<'PY'
import json,os,pathlib,sys
sys.path.insert(0,'discovery')
from sdk_m0_conformance import source_identity, check_build_receipt
assert all(pathlib.Path(p).exists() for p in sys.argv[2:]),'missing prebuilt M0 product'
logs=pathlib.Path(sys.argv[7])
assert logs.is_dir() and any(path.is_file() and path.stat().st_size for path in logs.iterdir()), \
    'missing or empty native build logs directory'
assert not any(key.startswith('SIMCTL_CHILD_CKSIM_') and value for key,value in os.environ.items()), \
    'Plain acceptance requires no inherited CKSIM child overrides'
check_build_receipt(pathlib.Path(sys.argv[6]),*(pathlib.Path(p) for p in sys.argv[2:6]))
if os.environ.get('SDK_M1_ACCEPTANCE') == '1':
    from sdk_m1_contracts_conformance import validate_build
    build=pathlib.Path(os.environ['SDK_M1_CONTRACT_BUILD'])
    validate_build(build)
if os.environ.get('SDK_SYSTEM_ACCEPTANCE') == '1':
    from sdk_system_conformance import package_check
    package_check(pathlib.Path(os.environ['SDK_SYSTEM_CONTROL_PACKAGE']),source_identity())
pathlib.Path(sys.argv[1]).write_text(json.dumps(source_identity(),indent=2)+'\n')
PY
# Keep raw runtime inventories, which contain local SDK paths, out of evidence.
# Cold host/device service queries have a bounded startup budget.
RUNTIME_JSON=$(limit 180 xcrun simctl list runtimes -j)
SDK_M0_RUNTIME_JSON="$RUNTIME_JSON" python3 - "${SDK_M0_RUNTIME:-}" "$OUT/runtime.json" <<'PY'
import json,os,pathlib,sys
rows=[r for r in json.loads(os.environ['SDK_M0_RUNTIME_JSON'])['runtimes']
      if r.get('platform')=='iOS' and r.get('isAvailable')]
if sys.argv[1]: rows=[r for r in rows if r['identifier']==sys.argv[1]]
assert rows,'requested iOS simulator runtime is unavailable'
selected=max(rows,key=lambda r:tuple(int(p) for p in r['version'].split('.')))
pathlib.Path(sys.argv[2]).write_text(json.dumps({k:selected[k] for k in
    ('identifier','version','buildversion')},indent=2)+'\n')
PY
RUNTIME=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identifier"])' "$OUT/runtime.json")
# Capture immutable host metadata once, before creating the owned simulator.
# The final environment below adds the actual simulator identity to these fields.
python3 - "$OUT/environment.json" <<'PY'
import json,pathlib,subprocess,sys
def output(command): return subprocess.check_output(command,text=True,timeout=30).strip()
environment=dict(
    xcodeVersion=output(['xcodebuild','-version']),sdkVersion=output(['xcrun','--sdk','iphonesimulator','--show-sdk-version']),
    hostArchitecture=output(['uname','-m']),nodeVersion=output(['node','--version']),npmVersion=output(['npm','--version']))
pathlib.Path(sys.argv[1]).write_text(json.dumps(environment,indent=2)+'\n')
PY
DEVTYPE=${SDK_M0_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}
UDID=$(limit 30 xcrun simctl create "sdk-m0-$RUN_ID" "$DEVTYPE" "$RUNTIME")
OWNED_SIMULATOR=$UDID
limit 60 xcrun simctl boot "$UDID"
limit 300 xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1
read_launch_environment
python3 - "$OUT" "$UDID" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); runtime=json.loads((root/'runtime.json').read_text())
environment=json.loads((root/'environment.json').read_text())
environment.update(simulatorID=sys.argv[2],simulatorRuntimeID=runtime['identifier'],
    simulatorOS=runtime['version'],simulatorBuild=runtime['buildversion'])
(root/'environment.json').write_text(json.dumps(environment,indent=2)+'\n')
PY
if [[ -n "${SDK_M0_BUILD_LOGS:-}" ]]; then
  python3 - "$SDK_M0_BUILD_LOGS" "$OUT/build-logs" <<'PY'
import pathlib,shutil,sys
source,target=map(pathlib.Path,sys.argv[1:]); target.mkdir()
assert source.is_dir(),'missing build logs directory'
for path in source.iterdir():
    if path.is_file():
        assert path.stat().st_size>0,'empty build log: '+path.name
        shutil.copyfile(path,target/path.name)
PY
fi
limit 180 xcrun simctl install "$UDID" "$SDK_M0_APP" > "$OUT/example-install.log" 2>&1
limit 180 xcrun simctl install "$UDID" "$SDK_M0_BOOTSTRAP_APP" > "$OUT/bootstrap-install.log" 2>&1
PRODUCT_CHECK=sdk-m0
# Plain --console preserves the app streams. The raw host PTY only flushes
# the launcher's stdio; --console-pty interleaved its PID header into PROBE JSON.
env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$INHERITED_DYLD" SIMCTL_CHILD_SDK_M0_ACCEPTANCE=1 \
  SIMCTL_CHILD_SDK_M0_RUN_ID="$RUN_ID" SIMCTL_CHILD_CKSIM_RUN_ID="$RUN_ID" \
  python3 discovery/run_scenario.py --console-launcher-stop --startup-timeout 180 --timeout 120 --output "$OUT/sdk-m0.log" --receipt "$OUT/sdk-m0.receipt.json" \
  --run-id "$RUN_ID" --simulator-id "$UDID" --scenario sdk-m0 --bundle-id dev.iosvoipsdk.example \
  --terminate-command xcrun simctl terminate "$UDID" dev.iosvoipsdk.example \
  --launch-command xcrun simctl launch --console --terminate-running-process "$UDID" dev.iosvoipsdk.example
if declare -F sim_checkpoint >/dev/null; then sim_checkpoint; fi
for case in healthy profile push-after-install; do
  PRODUCT_CHECK="bootstrap-$case"
  env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$INHERITED_DYLD" SIMCTL_CHILD_CKSIM_RUN_ID="$RUN_ID" \
    SIMCTL_CHILD_CKSIM_BOOTSTRAP_CASE="$case" \
    python3 discovery/run_scenario.py --console-launcher-stop --startup-timeout 180 --timeout 90 --output "$OUT/bootstrap-$case.log" --receipt "$OUT/bootstrap-$case.receipt.json" \
    --run-id "$RUN_ID" --simulator-id "$UDID" --scenario "bootstrap-$case" --bundle-id dev.callkitsim.sdkbootstrap \
    --terminate-command xcrun simctl terminate "$UDID" dev.callkitsim.sdkbootstrap \
    --launch-command xcrun simctl launch --console --terminate-running-process "$UDID" dev.callkitsim.sdkbootstrap
done
PRODUCT_CHECK=installed-bytes
# Each app publishes its canonical bundle URL. Bind it to the completed launch
# before reading installed bytes; avoid the two pre-launch CoreSimulator RPCs.
python3 discovery/sdk_installed_paths.py "$OUT" "$RUN_ID" "$UDID"
if [[ "${SDK_M1_ACCEPTANCE:-0}" == 1 ]]; then
  mkdir "$OUT/m1"
  # Reuse the first observed data container across relaunches of this installation.
  example_container=""
  for case in journey cold-launch unhandled-expiry; do
    if [[ "${SDK_M1_PART:-all}" != all && "${SDK_M1_PART:-all}" != journeys ]]; then break; fi
    name="sdk-m1-$case"
    PRODUCT_CHECK="$name"
    budget=90
    [[ "$case" != journey ]] || budget=120
    env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$INHERITED_DYLD" \
      SIMCTL_CHILD_CKSIM_RUN_ID="$RUN_ID" SIMCTL_CHILD_SDK_M0_RUN_ID="$RUN_ID" \
      SIMCTL_CHILD_SDK_M1_RUN_ID="$RUN_ID" SIMCTL_CHILD_SDK_M1_CASE="$case" \
      python3 discovery/run_scenario.py --console-launcher-stop --startup-timeout 180 --timeout "$budget" \
      --output "$OUT/m1/$name.log" --receipt "$OUT/m1/$name.receipt.json" \
      --run-id "$RUN_ID" --simulator-id "$UDID" --scenario "$name" --bundle-id dev.iosvoipsdk.example \
      --terminate-command xcrun simctl terminate "$UDID" dev.iosvoipsdk.example \
      --launch-command xcrun simctl launch --console --terminate-running-process "$UDID" dev.iosvoipsdk.example
    if [[ -z "$example_container" ]]; then
      example_container=$(limit 30 python3 scripts/sim/paths.py --receipt "$OUT/m1/$name.receipt.json" --trace "$OUT/m1/$name.log" \
        --simulator "$UDID" --run-id "$RUN_ID" --bundle dev.iosvoipsdk.example)
      [[ -n "$example_container" && -d "$example_container" ]] || { echo "Missing owned example data container" >&2; exit 1; }
    fi
    cp "$example_container/Documents/.callkit-simulator/$RUN_ID/events.jsonl" "$OUT/m1/$name.runtime.jsonl"
    python3 - "$OUT/m1/$name.receipt.json" "$OUT/m1/$name.runtime.jsonl" <<'PY'
import hashlib,json,pathlib,sys
receipt,journal=map(pathlib.Path,sys.argv[1:])
row=json.loads(receipt.read_text())
row['journalSHA256']=hashlib.sha256(journal.read_bytes()).hexdigest()
receipt.write_text(json.dumps(row,indent=2)+'\n')
PY
  done
  mkdir "$OUT/m1/contracts"
  if [[ "$SDK_M1_PART" == all || "$SDK_M1_PART" == contracts ]]; then
  cp -R "$SDK_M1_CONTRACT_BUILD" "$OUT/m1/contracts-build"
  limit 180 xcrun simctl install "$UDID" "$OUT/m1/contracts-build/SDKM1Contracts.app" > "$OUT/m1/contracts-install.log" 2>&1
  # The app is installed once and only relaunched below. Reuse its first
  # observed data container instead of making another IPC query after each case.
  contract_container=""
  for case in unhandled-accept unhandled-fail duplicate-wrapper media-reentrancy audio-lifecycle audio-routes; do
    name="sdk-m1-contract-$case"
    PRODUCT_CHECK="$name"
    env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$INHERITED_DYLD" \
      SIMCTL_CHILD_CKSIM_RUN_ID="$RUN_ID" SIMCTL_CHILD_SDK_M1_CONTRACT_CASE="$case" \
      python3 discovery/run_scenario.py --console-launcher-stop --startup-timeout 180 --timeout 90 \
      --output "$OUT/m1/contracts/$name.log" --receipt "$OUT/m1/contracts/$name.receipt.json" \
      --run-id "$RUN_ID" --simulator-id "$UDID" --scenario "$name" --bundle-id dev.iosvoipsdk.m1contracts \
      --terminate-command xcrun simctl terminate "$UDID" dev.iosvoipsdk.m1contracts \
      --launch-command xcrun simctl launch --console --terminate-running-process "$UDID" dev.iosvoipsdk.m1contracts
    if [[ -z "$contract_container" ]]; then
      contract_container=$(limit 30 python3 scripts/sim/paths.py --receipt "$OUT/m1/contracts/$name.receipt.json" --trace "$OUT/m1/contracts/$name.log" \
        --simulator "$UDID" --run-id "$RUN_ID" --bundle dev.iosvoipsdk.m1contracts)
      [[ -n "$contract_container" && -d "$contract_container" ]] || { echo "Missing owned contract data container" >&2; exit 1; }
    fi
    cp "$contract_container/Documents/.callkit-simulator/$RUN_ID/events.jsonl" "$OUT/m1/contracts/$name.runtime.jsonl"
    python3 - "$OUT/m1/contracts/$name.receipt.json" "$OUT/m1/contracts/$name.runtime.jsonl" <<'PY'
import hashlib,json,pathlib,sys
receipt,journal=map(pathlib.Path,sys.argv[1:])
row=json.loads(receipt.read_text())
row['journalSHA256']=hashlib.sha256(journal.read_bytes()).hexdigest()
receipt.write_text(json.dumps(row,indent=2)+'\n')
PY
  done
  fi
  if [[ "$SDK_M1_PART" == all || "$SDK_M1_PART" == push-entry ]]; then
  # Reuse this fresh owned simulator and its preserved launch environment. The
  # focused fixture runs three conforming deliveries and two required refusals;
  # these in-app injections do not stand in for a push-initiated cold launch.
  PRODUCT_CHECK=push-report-entry
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$INHERITED_DYLD" \
    python3 discovery/run_push_report_entry.py --build "$SDK_PUSH_ENTRY_BUILD" \
      --out "$OUT/push-entry" --simulator "$UDID"
  fi
fi
PRODUCT_CHECK=sdk-m3-direct
if [[ "${SDK_SYSTEM_ACCEPTANCE:-0}" == 1 ]]; then
  mkdir "$OUT/m3"
  env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$INHERITED_DYLD" \
    SIMCTL_CHILD_CKSIM_RUN_ID="$RUN_ID" SIMCTL_CHILD_SDK_M3_RUN_ID="$RUN_ID" SIMCTL_CHILD_SDK_M3_DIRECT=1 \
    python3 discovery/run_scenario.py --console-launcher-stop --startup-timeout 180 --timeout 60 \
    --output "$OUT/m3/sdk-m3-direct.log" --receipt "$OUT/m3/sdk-m3-direct.receipt.json" \
    --run-id "$RUN_ID" --simulator-id "$UDID" --scenario sdk-m3-direct --bundle-id dev.iosvoipsdk.example \
    --terminate-command xcrun simctl terminate "$UDID" dev.iosvoipsdk.example \
    --launch-command xcrun simctl launch --console --terminate-running-process "$UDID" dev.iosvoipsdk.example
  example_container=$(limit 30 python3 scripts/sim/paths.py --receipt "$OUT/m3/sdk-m3-direct.receipt.json" --trace "$OUT/m3/sdk-m3-direct.log" \
    --simulator "$UDID" --run-id "$RUN_ID" --bundle dev.iosvoipsdk.example)
  [[ -n "$example_container" && -d "$example_container" ]] || { echo "Missing owned dial-request data container" >&2; exit 1; }
  cp "$example_container/Documents/.callkit-simulator/$RUN_ID/events.jsonl" "$OUT/m3/sdk-m3-direct.runtime.jsonl"
  python3 discovery/sdk_dial_requests.py record "$OUT" --run-id "$RUN_ID" --simulator "$UDID"
fi
PRODUCT_CHECK=sdk-system
if [[ "${SDK_SYSTEM_ACCEPTANCE:-0}" == 1 ]]; then
  if [[ -z "${example_container:-}" ]]; then
    example_container=$(limit 30 python3 scripts/sim/paths.py --receipt "$OUT/sdk-m0.receipt.json" --trace "$OUT/sdk-m0.log" \
      --simulator "$UDID" --run-id "$RUN_ID" --bundle dev.iosvoipsdk.example)
    [[ -n "$example_container" && -d "$example_container" ]] || { echo "Missing owned example data container" >&2; exit 1; }
  fi
  env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$INHERITED_DYLD" \
    python3 discovery/run_sdk_system.py --simulator "$UDID" --run-id "$RUN_ID" \
    --package "$SDK_SYSTEM_CONTROL_PACKAGE" --output "$OUT/system" --data-container "$example_container"
fi
cleanup_simulator
redact_external_paths
PRODUCT_CHECK=manifest
SDK_M0_EXTERNAL_DYLD="$INHERITED_DYLD" python3 - "$OUT" "$SDK_M0_APP" "$SDK_M0_BOOTSTRAP_APP" \
  "$SDK_M0_DEVICE_PROBE" "$SDK_M0_SPM_DEVICE_DIR" "$SDK_M0_BUILD_RECEIPT" "$RUN_ID" "$OWNED_SIMULATOR" <<'PY'
import os,pathlib,sys
sys.path.insert(0,'discovery')
from sdk_m0_conformance import record_manifest
record_manifest(*(pathlib.Path(p) for p in sys.argv[1:7]),*sys.argv[7:],os.environ['SDK_M0_EXTERNAL_DYLD'])
PY
PRODUCT_CHECK=sdk-m0-conformance
python3 discovery/sdk_m0_conformance.py "$OUT" | tee "$OUT/summary.json"
if [[ "${SDK_SYSTEM_ACCEPTANCE:-0}" == 1 ]]; then
  PRODUCT_CHECK=sdk-m3-conformance
  python3 discovery/sdk_dial_requests.py validate "$OUT" | tee "$OUT/m3/summary.json"
  PRODUCT_CHECK=sdk-system-conformance
  python3 discovery/sdk_system_conformance.py "$OUT" --record
  python3 discovery/sdk_system_conformance.py "$OUT" | tee "$OUT/system/summary.json"
fi
if [[ "${SDK_M1_ACCEPTANCE:-0}" == 1 ]]; then
  if [[ "$SDK_M1_PART" == all || "$SDK_M1_PART" == journeys ]]; then
  PRODUCT_CHECK=sdk-m1-conformance
  python3 discovery/sdk_m1_conformance.py "$OUT" | tee "$OUT/m1/summary.json"
  fi
  if [[ "$SDK_M1_PART" == all || "$SDK_M1_PART" == contracts ]]; then
  PRODUCT_CHECK=sdk-m1-contracts-conformance
  python3 discovery/sdk_m1_contracts_conformance.py "$OUT/m1/contracts-build" "$OUT/m1/contracts" --parent-manifest "$OUT/manifest.json" | tee "$OUT/m1/contracts/summary.json"
  fi
fi
