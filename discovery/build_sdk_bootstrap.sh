#!/bin/bash
# Build the source bootstrap regression app; this script never creates a simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?provide a fresh output directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET="${CKSIM_BUILD_ARCH:-$(uname -m)}-apple-ios26.0-simulator"
VERSION=$(cat VERSION)
WORK=$(mktemp -d "$OUT/.build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
APP="$OUT/SDKBootstrap.app"
mkdir -p "$APP/IosVoipSDKRuntime.bundle"
cp Sources/Engine/Resources/ios-27.0.json "$APP/IosVoipSDKRuntime.bundle/"
python3 - "$APP/Info.plist" <<'PY'
import pathlib,plistlib,sys
info=plistlib.loads(pathlib.Path('discovery/probe/Info.plist').read_bytes())
info['CFBundleIdentifier']='dev.callkitsim.sdkbootstrap'
info['CFBundleExecutable']='SDKBootstrap'
info['UIApplicationSceneManifest']={'UIApplicationSupportsMultipleScenes':False,
    'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'SDK Bootstrap',
                                                                  'UISceneDelegateClassName':'SDKBootstrapScene'}]}}
path=pathlib.Path(sys.argv[1])
path.write_bytes(plistlib.dumps(info))
resource=dict(CFBundleIdentifier='dev.callkitsim.sdkbootstrap.runtime',CFBundleName='IosVoipSDKRuntime',
              CFBundlePackageType='BNDL',CFBundleVersion='1')
(path.parent/'IosVoipSDKRuntime.bundle/Info.plist').write_bytes(plistlib.dumps(resource))
PY
for source in CKInterposition CKPushDelivery CKPushLaunch; do
  xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fmodules \
    -DCKSIM_SDK_SOURCE=1 -DCKSIM_ABI_TESTING=1 -DCKSIM_RUNTIME_VERSION=\""$VERSION"\" \
    -c "Sources/Interposition/$source.m" -o "$WORK/$source.o"
done
xcrun --sdk iphonesimulator swiftc -target "$TARGET" -sdk "$SDK" -swift-version 6 -parse-as-library \
  -import-objc-header Sources/Interposition/CKRuntimeSeam.h Sources/CKSimProtocol/*.swift Sources/Engine/RuntimeEngine.swift \
  Sources/VoIPSDK/SimulatorSupport.swift discovery/probe/sdk_bootstrap.swift "$WORK/CKInterposition.o" "$WORK/CKPushDelivery.o" "$WORK/CKPushLaunch.o" \
  -o "$APP/SDKBootstrap"
codesign -s - --force "$APP"
