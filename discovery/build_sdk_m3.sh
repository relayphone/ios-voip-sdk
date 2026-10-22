#!/bin/bash
# Build only the default-media example and public Settings UI test. No simulator starts.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?provide a fresh build directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
python3 discovery/sdk_m0_conformance.py --begin-build "$OUT/source-before.json"
python3 - <<'PY'
import json,pathlib
assert json.loads(pathlib.Path('example/ios/Podfile.properties.json').read_text())['ios-voip-sdk.mediaAdapter']=='none'
PY
DD=${SDK_M3_DERIVED_DATA:-$OUT/expo}
SDK_EXAMPLE_MEDIA_ADAPTER=none limit 1800 xcodebuild \
  -workspace example/ios/VoIPSDKExample.xcworkspace -scheme VoIPSDKExample \
  -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  COMPILER_INDEX_STORE_ENABLE=NO build > "$OUT/example-build.log" 2>&1
cp -R "$DD/Build/Products/Release-iphonesimulator/VoIPSDKExample.app" "$OUT/Example.app"
mkdir "$OUT/settings-source"
cp discovery/m3-settings/* "$OUT/settings-source/"
limit 60 xcodegen generate --spec "$OUT/settings-source/project.yml" > "$OUT/settings-generate.log" 2>&1
TEST_DD=${SDK_M3_SETTINGS_DERIVED_DATA:-$OUT/settings-derived}
limit 300 xcodebuild build-for-testing -project "$OUT/settings-source/SDKM3SettingsProbe.xcodeproj" \
  -scheme SDKM3SettingsProbe -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$TEST_DD" ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO > "$OUT/settings-build.log" 2>&1
cp -R "$TEST_DD/Build/Products" "$OUT/settings-products"
python3 - "$OUT" <<'PY'
import json,pathlib,sys
sys.path.insert(0,'discovery')
import sdk_m0_conformance as m0
import sdk_m3_conformance as m3
root=pathlib.Path(sys.argv[1]); identity=m0.source_identity()
assert json.loads((root/'source-before.json').read_text())==identity,'sources changed during M3 build'
app=root/'Example.app'
claims=m3.simulated_entitlements(m0.executable(app)); (root/'simulated-entitlements.plist').write_bytes(claims)
receipt=dict(schemaVersion=1,product='sdk-m3',configuration='Release',mediaAdapter='none',
             sourceStart=identity,sourceEnd=identity,**identity,
             files={'binaries/example':m0.digest(m0.executable(app)), 'binaries/main.jsbundle':m0.digest(app/'main.jsbundle'),'Info.plist':m0.digest(app/'Info.plist')},
             settingsProducts=m3.product_files(root/'settings-products'),
             buildLogs={name:m0.digest(root/name) for name in ('example-build.log','settings-generate.log','settings-build.log')})
(root/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
m3.check_input_build(app,receipt,identity,root/'settings-products')
PY
echo "Built source-bound M3 products at $OUT; no simulator was used."
