#!/bin/bash
# Link every shared source into a device Mach-O; never install or execute it.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?provide a fresh output directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "$OUT/.device-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
SDK=$(limit 30 xcrun --sdk iphoneos --show-sdk-path)
TARGET=arm64-apple-ios17.4
VERSION=$(cat VERSION)
cat > "$WORK/main.swift" <<'SWIFT'
@main
struct SDKDeviceProbe {
  @MainActor static func main() {
    print(SimulatorSupport.activateIfNeeded())
  }
}
SWIFT
cat > "$WORK/SDKDeviceHeaders.h" <<HEADERS
#import "$PWD/Sources/Interposition/CKRuntimeSeam.h"
#import "$PWD/Sources/VoIPPlatform/include/VoIPPlatform.h"
HEADERS
for source in Sources/Interposition/CKInterposition.m Sources/Interposition/CKPushDelivery.m Sources/Interposition/CKPushLaunch.m Sources/VoIPPlatform/*.m; do
  object=$(basename "$source" .m)
  limit 90 xcrun --sdk iphoneos clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fmodules \
    -DCKSIM_SDK_SOURCE=1 -DCKSIM_RUNTIME_VERSION=\""$VERSION"\" \
    -c "$source" -o "$WORK/$object.o"
done
limit 180 xcrun --sdk iphoneos swiftc -target "$TARGET" -sdk "$SDK" -swift-version 6 -parse-as-library \
  -import-objc-header "$WORK/SDKDeviceHeaders.h" Sources/Engine/*.swift \
  Sources/VoIPSDK/*.swift "$WORK/main.swift" "$WORK/"*.o \
  -o "$OUT/SDKDeviceProbe"
python3 - "$OUT" "$TARGET" <<'PY'
import hashlib,json,pathlib,subprocess,sys
sys.path.insert(0,'discovery')
from sdk_m0_conformance import source_identity
root=pathlib.Path(sys.argv[1])
info=dict(product='unified-shared-source-device',target=sys.argv[2],**source_identity(),
          sdkVersion=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).strip(),
          binarySHA256=hashlib.sha256((root/'SDKDeviceProbe').read_bytes()).hexdigest())
(root/'SDKDeviceProbe.build-info.json').write_text(json.dumps(info,indent=2)+'\n')
PY
echo 'Shared-source device link probe built; no device was used.'
