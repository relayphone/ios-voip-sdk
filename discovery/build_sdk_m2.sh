#!/bin/bash
# Build selected LiveKit products from already installed locked dependencies.
# Prepare with SDK_EXAMPLE_MEDIA_ADAPTER=livekit expo prebuild, then pod install
# from example/ios. This script never starts a simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?provide a fresh build directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
mkdir "$OUT/apps" "$OUT/binaries" "$OUT/products"
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
python3 - "$OUT/source-before.json" <<'PY'
import json,pathlib,sys
sys.path.insert(0,'discovery')
from sdk_m2_conformance import source_identity
pathlib.Path(sys.argv[1]).write_text(json.dumps(source_identity(),indent=2)+'\n')
PY
DD=${SDK_M2_DERIVED_DATA:-$OUT/expo}
SDK_EXAMPLE_MEDIA_ADAPTER=livekit limit 1800 xcodebuild \
  -workspace example/ios/VoIPSDKExample.xcworkspace -scheme VoIPSDKExample \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DD" ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build > "$OUT/example-build.log" 2>&1
cp -R "$DD/Build/Products/Release-iphonesimulator/VoIPSDKExample.app" "$OUT/apps/example.app"
bash discovery/build_sdk_m1_contracts.sh "$OUT/contracts" > "$OUT/contracts-build.log" 2>&1
cp -R "$OUT/contracts/SDKM1Contracts.app" "$OUT/apps/contracts.app"
SDK=$(limit 30 xcrun --sdk iphonesimulator --show-sdk-path)
limit 90 xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios17.4-simulator" \
  -isysroot "$SDK" Tools/cksim-notify.c -o "$OUT/binaries/cksim-notify" > "$OUT/notifier-build.log" 2>&1
limit 30 codesign -s - --force "$OUT/binaries/cksim-notify" >> "$OUT/notifier-build.log" 2>&1
python3 - "$OUT" <<'PY'
import json,pathlib,plistlib,shutil,sys
sys.path.insert(0,'discovery')
from sdk_m0_conformance import executable
from sdk_m2_conformance import PRODUCT_FILES,digest,source_identity,validate_build
root=pathlib.Path(sys.argv[1]); app=root/'apps/example.app'
copies={
 'binaries/example':executable(app),'binaries/main.jsbundle':app/'main.jsbundle',
 'binaries/livekit-webrtc':app/'Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC',
 'products/LiveKitWebRTC.Info.plist':app/'Frameworks/LiveKitWebRTC.framework/Info.plist',
 'binaries/contracts':executable(root/'apps/contracts.app'),
 'products/Podfile.lock':pathlib.Path('example/ios/Podfile.lock'),
 'products/Podfile.properties.json':pathlib.Path('example/ios/Podfile.properties.json'),
 'products/Info.plist':app/'Info.plist',
 'products/IosVoipSDK.podspec.json':pathlib.Path('example/ios/Pods/Local Podspecs/IosVoipSDK.podspec.json'),
 'products/ios-27.0.json':pathlib.Path('Sources/Engine/Resources/ios-27.0.json'),
 'products/contracts-build-info.json':root/'contracts/build-info.json'}
for name,path in copies.items(): shutil.copyfile(path,root/name)
packages=('@livekit/react-native','@livekit/react-native-webrtc','livekit-client','react-dom')
versions={name:json.loads((pathlib.Path('node_modules')/name/'package.json').read_text())['version'] for name in packages}
(root/'products/versions.json').write_text(json.dumps(versions,indent=2)+'\n')
after=source_identity(); before=json.loads((root/'source-before.json').read_text())
assert before==after,'sources changed during M2 build'
(root/'source-after.json').write_text(json.dumps(after,indent=2)+'\n')
info=dict(schemaVersion=1,product='sdk-m2',configuration='Release',contractsConfiguration='Debug',
          mediaAdapter='livekit',sourceStart=before,sourceEnd=after,**after,
          files={name:digest(root/name) for name in PRODUCT_FILES})
(root/'build-info.json').write_text(json.dumps(info,indent=2)+'\n')
validate_build(root,after)
PY
echo "Built source-bound M2 products at $OUT; no simulator was used."
