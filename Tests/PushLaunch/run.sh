#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cksim-push-launch.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
clang -fobjc-arc -fmodules -framework Foundation -DCKSIM_PUSH_LAUNCH_HOST_TEST=1 \
  -I Sources/Interposition Sources/Interposition/CKPushLaunch.m Tests/PushLaunch/main.m -o "$WORK/test"
"$WORK/test"
