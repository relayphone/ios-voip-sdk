#!/bin/bash
# Run the SDK 27-built contract app on one owned iOS 26.5 simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SDK_M1_CONTRACT_BUILD:?provide the downloaded SDK 27 Debug contract build}"
if [[ -n "${OUT:-}" ]]; then mkdir "$OUT"; else OUT=$(mktemp -d "${TMPDIR:-/tmp}/sdk-audio-legacy.XXXXXX"); fi
OUT=$(cd "$OUT" && pwd)
UDID=""
INHERITED_DYLD=""
RUN_ID=$(uuidgen)
BUNDLE=dev.iosvoipsdk.m1contracts
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-5
NAME=sdk-m1-contract-audio-lifecycle
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
cleanup_simulator() {
  [[ -n "$UDID" ]] || return 0
  local shutdown_status=0 delete_status=0
  limit 30 xcrun simctl shutdown "$UDID" >> "$OUT/cleanup.log" 2>&1 || shutdown_status=$?
  limit 30 xcrun simctl delete "$UDID" >> "$OUT/cleanup.log" 2>&1 || delete_status=$?
  python3 - "$OUT/cleanup.json" "$UDID" "$shutdown_status" "$delete_status" <<'PY'
import json,pathlib,sys
path,sim,shutdown,delete=sys.argv[1:]
pathlib.Path(path).write_text(json.dumps(dict(simulatorID=sim,shutdownExitCode=int(shutdown),
    deleteExitCode=int(delete),deleted=int(delete)==0),indent=2)+'\n')
PY
  if [[ "$delete_status" -eq 0 ]]; then UDID=""; else return 1; fi
}
redact_external_paths() {
  [[ -n "$INHERITED_DYLD" ]] || return 0
  SDK_AUDIO_EXTERNAL_DYLD="$INHERITED_DYLD" python3 - "$OUT" <<'PYCODE'
import hashlib,json,os,pathlib,sys
paths=[p.encode() for p in os.environ['SDK_AUDIO_EXTERNAL_DYLD'].split(':') if p]
for log in pathlib.Path(sys.argv[1]).glob('*.log'):
    original=data=log.read_bytes()
    for path in paths: data=data.replace(path,b'<inherited-external-library>')
    if original==data: continue
    log.write_bytes(data); receipt=log.with_suffix('.receipt.json')
    if receipt.exists():
        row=json.loads(receipt.read_text()); row['unredactedTraceSHA256']=row['traceSHA256']
        row.update(traceSHA256=hashlib.sha256(data).hexdigest(),externalLibraryPathsRedacted=True)
        receipt.write_text(json.dumps(row,indent=2)+'\n')
PYCODE
}
cleanup() {
  local status=$?
  trap - EXIT
  cleanup_simulator || status=1
  redact_external_paths || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - "$SDK_M1_CONTRACT_BUILD" <<'PY'
import os,pathlib,sys
sys.path.insert(0,'discovery')
from sdk_m1_contracts_conformance import validate_build
assert not any(k.startswith('SIMCTL_CHILD_CKSIM_') and v for k,v in os.environ.items()),'inherited runtime overrides refused'
info,_=validate_build(pathlib.Path(sys.argv[1]))
assert int(info['sdkVersion'].split('.')[0]) >= 27,'legacy runtime requires the SDK 27-built app'
PY
RUNTIME_JSON=$(limit 60 xcrun simctl list runtimes -j)
SDK_AUDIO_RUNTIME_JSON="$RUNTIME_JSON" python3 - "$RUNTIME" "$OUT/runtime.json" <<'PY'
import json,os,pathlib,sys
rows=[r for r in json.loads(os.environ['SDK_AUDIO_RUNTIME_JSON'])['runtimes']
      if r.get('identifier')==sys.argv[1] and r.get('platform')=='iOS' and r.get('isAvailable')]
assert len(rows)==1 and rows[0]['version']=='26.5','requested iOS 26.5 runtime is unavailable'
pathlib.Path(sys.argv[2]).write_text(json.dumps({k:rows[0][k] for k in
    ('identifier','version','buildversion')},indent=2)+'\n')
PY
UDID=$(limit 30 xcrun simctl create "sdk-audio-legacy-$RUN_ID" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$RUNTIME")
limit 60 xcrun simctl boot "$UDID"
limit 300 xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1
if [[ -n "${SIMCTL_CHILD_DYLD_INSERT_LIBRARIES+x}" ]]; then
  INHERITED_DYLD=$SIMCTL_CHILD_DYLD_INSERT_LIBRARIES
else
  query_status=0
  INHERITED_DYLD=$(SIMCTL_CHILD_DYLD_INSERT_LIBRARIES='' limit 180 xcrun simctl spawn "$UDID" launchctl getenv DYLD_INSERT_LIBRARIES 2> "$OUT/launch-environment-query.log") || query_status=$?
  printf 'Query exit code: %s\n' "$query_status" >> "$OUT/launch-environment-query.log"
  [[ "$query_status" -le 1 ]] || { echo 'Cannot read inherited launch environment' >&2; exit 1; }
fi
SDK_AUDIO_EXTERNAL_DYLD="$INHERITED_DYLD" python3 - <<'PY'
import os,pathlib
assert not any(pathlib.Path(p).name in ('CKSimRuntime.dylib','CKSimLoader.dylib')
    for p in os.environ['SDK_AUDIO_EXTERNAL_DYLD'].split(':') if p),'external SDK runtime injection refused'
PY
limit 180 xcrun simctl install "$UDID" "$SDK_M1_CONTRACT_BUILD/SDKM1Contracts.app" > "$OUT/install.log" 2>&1
env SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$INHERITED_DYLD" \
  SIMCTL_CHILD_CKSIM_RUN_ID="$RUN_ID" SIMCTL_CHILD_SDK_M0_RUN_ID="$RUN_ID" \
  SIMCTL_CHILD_SDK_M1_CONTRACT_CASE=audio-lifecycle \
  python3 discovery/run_scenario.py --console-launcher-stop --timeout 90 \
  --output "$OUT/$NAME.log" --receipt "$OUT/$NAME.receipt.json" \
  --run-id "$RUN_ID" --simulator-id "$UDID" --scenario "$NAME" --bundle-id "$BUNDLE" \
  --terminate-command xcrun simctl terminate "$UDID" "$BUNDLE" \
  --launch-command xcrun simctl launch --console --terminate-running-process "$UDID" "$BUNDLE"
container=$(limit 30 env -u SIMCTL_CHILD_DYLD_INSERT_LIBRARIES xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
[[ -n "$container" && -d "$container" ]] || { echo 'Missing owned contract data container' >&2; exit 1; }
cp "$container/Documents/.callkit-simulator/$RUN_ID/events.jsonl" "$OUT/$NAME.runtime.jsonl"
python3 - "$OUT/$NAME.receipt.json" "$OUT/$NAME.runtime.jsonl" <<'PY'
import hashlib,json,pathlib,sys
receipt,journal=map(pathlib.Path,sys.argv[1:])
row=json.loads(receipt.read_text()); row['journalSHA256']=hashlib.sha256(journal.read_bytes()).hexdigest()
receipt.write_text(json.dumps(row,indent=2)+'\n')
PY
cleanup_simulator
redact_external_paths
python3 discovery/sdk_m1_contracts_conformance.py "$SDK_M1_CONTRACT_BUILD" "$OUT" --case audio-lifecycle | tee "$OUT/summary.json"
python3 - "$OUT/summary.json" <<'PYCODE'
import json,pathlib,sys
result=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result['simulatorOS'].split('.')[:2]==['26','5'],'app executed on an unexpected OS'
assert result['cases']['audio-lifecycle']['path']=='legacy','legacy notification branch was not exercised'
PYCODE
