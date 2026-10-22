#!/bin/bash
# Host-only transport regression; no app build or simulator is used.
set -euo pipefail
cd "$(dirname "$0")/../.."
TRACE_TEST_OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/ios-voip-probe-writer.XXXXXX")
trap 'rm -rf "$TRACE_TEST_OUTPUT"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  example/modules/journey/apple/ProbeTraceWriter.swift Tests/ProbeTraceWriter/Tests.swift \
  -o "$TRACE_TEST_OUTPUT/ProbeTraceTests"
python3 - "$TRACE_TEST_OUTPUT/ProbeTraceTests" <<'PY'
import json,subprocess,sys
result=subprocess.run([sys.argv[1]],capture_output=True,text=True,timeout=10)
assert result.returncode==0,result.stderr
rows=[json.loads(line.removeprefix('PROBE ')) for line in result.stderr.splitlines()]
assert len(rows)==1 and rows[0]['event']=='host.defaultWrite','default descriptor/frame differs'
print(result.stdout,end='')
PY
