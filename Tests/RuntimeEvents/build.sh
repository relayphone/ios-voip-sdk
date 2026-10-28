#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=${1:?provide a fresh output directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET="$(uname -m)-apple-ios18.0-simulator"
VERSION=$(cat VERSION)
APP="$OUT/RuntimeEventFixture.app"
mkdir "$APP"
for source in CKInterposition CKPushDelivery CKPushLaunch; do
  xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fmodules \
    -DCKSIM_SDK_SOURCE=1 -DCKSIM_RUNTIME_VERSION=\""$VERSION"\" \
    -c "Sources/Interposition/$source.m" -o "$OUT/$source.o"
done
xcrun --sdk iphonesimulator swiftc -target "$TARGET" -sdk "$SDK" -swift-version 6 -parse-as-library \
  -DCKSIM_SDK_SOURCE -import-objc-header Sources/Interposition/CKRuntimeSeam.h Sources/Engine/RuntimeEngine.swift \
  Inspector/ForegroundPhaseProbe.swift Tests/RuntimeEvents/Fixture.swift \
  "$OUT/CKInterposition.o" "$OUT/CKPushDelivery.o" "$OUT/CKPushLaunch.o" -o "$APP/RuntimeEventFixture"
python3 - "$APP/Info.plist" <<'PY'
import pathlib,plistlib,sys
info=plistlib.loads(pathlib.Path('discovery/probe/Info.plist').read_bytes())
info.update(CFBundleIdentifier='dev.callkitsim.eventfixture',CFBundleExecutable='RuntimeEventFixture',
            CFBundleName='Runtime Event Fixture',CFBundleDisplayName='Event Fixture')
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
codesign -s - --force "$APP"
rm "$OUT/"*.o
