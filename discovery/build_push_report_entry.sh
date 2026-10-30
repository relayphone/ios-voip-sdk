#!/bin/bash
# One source-built scene-capable simulator probe. Never creates or boots a simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?provide a fresh output directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
python3 - "$OUT/source-before.json" <<'PY'
import json,pathlib,sys
sys.path.insert(0,'discovery')
from check_push_report_entry import native_source_identity
pathlib.Path(sys.argv[1]).write_text(json.dumps(native_source_identity(),indent=2)+'\n')
PY
SDK=$(limit 30 xcrun --sdk iphonesimulator --show-sdk-path)
TARGET="$(uname -m)-apple-ios17.4-simulator"
VERSION=$(cat VERSION)
WORK=$(mktemp -d "$OUT/.build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
APP="$OUT/PushEntry.app"
mkdir -p "$APP/IosVoipSDKRuntime.bundle"
cp Sources/Engine/Resources/ios-27.0.json "$APP/IosVoipSDKRuntime.bundle/"
python3 - "$APP/Info.plist" <<'PY'
import pathlib,plistlib,sys
path=pathlib.Path(sys.argv[1])
info=plistlib.loads(pathlib.Path('discovery/probe/Info.plist').read_bytes())
info.update(CFBundleIdentifier='dev.iosvoipsdk.pushentry',CFBundleExecutable='PushEntry',MinimumOSVersion='17.4')
path.write_bytes(plistlib.dumps(info))
(path.parent/'IosVoipSDKRuntime.bundle/Info.plist').write_bytes(plistlib.dumps(dict(
 CFBundleIdentifier='dev.iosvoipsdk.pushentry.runtime',CFBundlePackageType='BNDL',CFBundleVersion='1')))
PY
cat > "$WORK/Headers.h" <<HEADERS
#import "$PWD/Sources/Interposition/CKRuntimeSeam.h"
#import "$PWD/Sources/VoIPPlatform/include/VoIPPlatform.h"
#import "$PWD/discovery/probe/push_entry_main_stall.h"
HEADERS
for source in Sources/Interposition/CKInterposition.m Sources/Interposition/CKPushDelivery.m Sources/Interposition/CKPushLaunch.m Sources/VoIPPlatform/*.m discovery/probe/push_entry_main_stall.m; do
  limit 90 xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fmodules \
    -DDEBUG=1 -DCKSIM_SDK_SOURCE=1 -DCKSIM_RUNTIME_VERSION=\""$VERSION"\" \
    -c "$source" -o "$WORK/$(basename "$source" .m).o" >> "$OUT/build.log" 2>&1
done
limit 180 xcrun --sdk iphonesimulator swiftc -target "$TARGET" -sdk "$SDK" -swift-version 6 -D DEBUG -parse-as-library \
  -module-cache-path "$WORK/modules" -import-objc-header "$WORK/Headers.h" Sources/CKSimProtocol/*.swift Sources/Engine/*.swift Sources/VoIPSDK/*.swift \
  discovery/probe/push_report_entry.swift "$WORK/"*.o -o "$APP/PushEntry" >> "$OUT/build.log" 2>&1
limit 30 codesign -s - --force "$APP" >> "$OUT/build.log" 2>&1
python3 - "$OUT" <<'PY'
import hashlib,json,pathlib,sys
sys.path.insert(0,'discovery')
from check_push_report_entry import native_source_identity
root=pathlib.Path(sys.argv[1]); identity=native_source_identity()
assert json.loads((root/'source-before.json').read_text()) == identity,'source changed during build'
files=['PushEntry.app/PushEntry','PushEntry.app/Info.plist','PushEntry.app/IosVoipSDKRuntime.bundle/ios-27.0.json']
(root/'build-receipt.json').write_text(json.dumps(dict(schemaVersion=1,classification='simulator-source-probe',
 source=identity,files={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in files}),indent=2)+'\n')
PY
