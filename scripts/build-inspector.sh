#!/bin/bash
# Separate, simulator-only SwiftUI app. No SDK dependency or device target.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?provide a fresh output directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
APP="$OUT/CKSimInspector.app"
mkdir "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios17.4-simulator" -sdk "$SDK" \
  -swift-version 6 -parse-as-library Sources/CKSimProtocol/*.swift Inspector/*.swift -o "$APP/CKSimInspector"
python3 - "$APP/Info.plist" <<'PY'
import pathlib,plistlib,sys
info=dict(CFBundleIdentifier='dev.callkitsim.inspector',CFBundleExecutable='CKSimInspector',
          CFBundleName='Call Inspector',CFBundleDisplayName='Call Inspector',CFBundlePackageType='APPL',
          CFBundleShortVersionString='1.0',CFBundleVersion='1',MinimumOSVersion='17.4',UIDeviceFamily=[1],
          UILaunchScreen={},UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False},
          NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
codesign -s - --force "$APP"
