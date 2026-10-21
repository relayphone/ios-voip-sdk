#!/bin/bash
set -euo pipefail
DIST=$(cd "${1:?pass a complete runtime distribution}" && pwd)
OUT=${2:?pass a fresh artifact directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$DIST" <<'PY'
import importlib.machinery,importlib.util,pathlib,sys
root=pathlib.Path(sys.argv[1]);loader=importlib.machinery.SourceFileLoader('cksim',str(root/'cksim'))
spec=importlib.util.spec_from_loader('cksim',loader);module=importlib.util.module_from_spec(spec);loader.exec_module(module)
module.validate_package(root)
PY
COPYFILE_DISABLE=1 tar -czf "$OUT/callkit-simulator-v0.1-macos.tar.gz" -C "$DIST" .
(cd "$OUT" && shasum -a 256 callkit-simulator-v0.1-macos.tar.gz > SHA256SUMS)
