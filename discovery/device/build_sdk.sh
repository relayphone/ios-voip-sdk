#!/bin/bash
# Build the source SDK device fixture. Never install, launch or select a device.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
: "${SDK_DEVICE_BUNDLE_ID:?set the approved QA app bundle identifier}"
: "${SDK_DEVICE_TEAM_ID:?set the approved development team identifier}"
OUT=${1:?provide a fresh private output directory}
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }

OUT=$(python3 - "$OUT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys

root = Path.cwd().resolve()
bundle = os.environ['SDK_DEVICE_BUNDLE_ID']
team = os.environ['SDK_DEVICE_TEAM_ID']
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+', bundle):
    raise SystemExit('SDK_DEVICE_BUNDLE_ID must be an explicit app bundle identifier.')
if not re.fullmatch(r'[A-Z0-9]{10}', team):
    raise SystemExit('SDK_DEVICE_TEAM_ID must be a development team identifier.')
requested = Path(sys.argv[1]).expanduser()
if requested.exists() or requested.is_symlink():
    raise SystemExit('Output must be fresh; existing output is never reused.')
out = requested.resolve()
private = root / '.env'
if private in out.parents:
    if private.is_symlink():
        raise SystemExit('The private output parent must not be a symlink.')
    if not private.exists():
        private.mkdir(mode=0o700)
    check = subprocess.run(['git', 'check-ignore', '-q', '--', str(out)], cwd=root)
    if check.returncode != 0:
        raise SystemExit('Repository-local device output must remain ignored.')
    ancestor = out.parent
    while not ancestor.exists():
        ancestor = ancestor.parent
    info = ancestor.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise SystemExit('The private output parent must be caller-owned with mode 0700.')
    out.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
else:
    if not out.parent.is_dir():
        raise SystemExit('Create a caller-owned mode-0700 output parent first.')
    info = out.parent.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise SystemExit('The output parent must be caller-owned with mode 0700.')

swift = sorted((root / 'Sources/VoIPSDK').glob('*.swift'))
objc = sorted((root / 'Sources/VoIPPlatform').glob('*.m'))
headers = sorted((root / 'Sources/VoIPPlatform').rglob('*.h'))
fixture = [root / 'discovery/device/SDKDeviceProbe.swift',
           root / 'discovery/device/DeviceQAStorage.swift']
inputs = sorted(set(swift + objc + headers + fixture + [root / 'discovery/device/build_sdk.sh']))
if not swift or not objc or not headers or any(not path.is_file() or not path.stat().st_size for path in inputs):
    raise SystemExit('Canonical SDK and device fixture sources must be present and nonempty.')
names = [str(path.relative_to(root)) for path in inputs]
scope = ['Sources/VoIPSDK', 'Sources/VoIPPlatform', 'discovery/device/SDKDeviceProbe.swift',
         'discovery/device/DeviceQAStorage.swift', 'discovery/device/build_sdk.sh']
dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--', *scope], cwd=root)
if dirty:
    raise SystemExit('Commit the SDK device build inputs before building measurement evidence.')
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
combined = hashlib.sha256()
inventory = []
for name, path in zip(names, inputs):
    data = path.read_bytes()
    combined.update(name.encode() + b'\0' + data + b'\0')
    inventory.append(dict(path=name, sha256=hashlib.sha256(data).hexdigest()))
identity = dict(schemaVersion=1, sourceCommit=commit, sourceInputsSHA256=combined.hexdigest(), inputs=inventory)

out.mkdir(mode=0o700)
(out / 'source-build-start.json').write_text(json.dumps(identity, indent=2) + '\n')
(out / 'SDKDeviceHeaders.h').write_text('#import ' + json.dumps(str(root / 'Sources/VoIPPlatform/include/VoIPPlatform.h')) + '\n')
info = dict(CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleExecutable='$(EXECUTABLE_NAME)',
            CFBundleName='$(PRODUCT_NAME)', CFBundleDisplayName='SDK Device QA', CFBundlePackageType='APPL',
            CFBundleShortVersionString='1.0', CFBundleVersion='1', MinimumOSVersion='17.4',
            LSRequiresIPhoneOS=True, UILaunchScreen={}, UIBackgroundModes=['voip', 'audio'],
            NSMicrophoneUsageDescription='Device QA measures SDK call audio.',
            UIApplicationSceneManifest=dict(UIApplicationSupportsMultipleScenes=False),
            SDKDeviceQASourceCommit=commit, SDKDeviceQASourceInputsSHA256=identity['sourceInputsSHA256'])
(out / 'Info.plist').write_bytes(plistlib.dumps(info))
(out / 'SDKDeviceProbe.entitlements').write_bytes(plistlib.dumps({'aps-environment': 'development'}))
settings = dict(SWIFT_VERSION='6.0', CODE_SIGN_STYLE='Automatic', DEVELOPMENT_TEAM=team,
                PRODUCT_BUNDLE_IDENTIFIER=bundle, PRODUCT_NAME='SDKDeviceProbe',
                PRODUCT_MODULE_NAME='SDKDeviceProbe', INFOPLIST_FILE=str(out / 'Info.plist'),
                GENERATE_INFOPLIST_FILE='NO', CODE_SIGN_ENTITLEMENTS=str(out / 'SDKDeviceProbe.entitlements'),
                SWIFT_OBJC_BRIDGING_HEADER=str(out / 'SDKDeviceHeaders.h'), TARGETED_DEVICE_FAMILY='1',
                SUPPORTED_PLATFORMS='iphoneos', SDKROOT='iphoneos', ARCHS='arm64',
                COMPILER_INDEX_STORE_ENABLE='NO',
                GCC_PREPROCESSOR_DEFINITIONS=['$(inherited)', 'DEBUG=1', 'SDK_DEVICE_QA=1'],
                SWIFT_ACTIVE_COMPILATION_CONDITIONS=['$(inherited)', 'DEBUG', 'SDK_DEVICE_QA'],
                OTHER_SWIFT_FLAGS=['$(inherited)', '-parse-as-library'])
project = dict(name='SDKDeviceQA', options=dict(deploymentTarget=dict(iOS='17.4')),
               targets=dict(SDKDeviceProbe=dict(type='application', platform='iOS',
                   sources=[dict(path=str(path)) for path in swift + objc + fixture],
                   settings=dict(base=settings))),
               schemes=dict(SDKDeviceProbe=dict(build=dict(targets=dict(SDKDeviceProbe='all')))))
(out / 'project.json').write_text(json.dumps(project, indent=2) + '\n')
print(out)
PY
)

limit 60 xcodegen generate --spec "$OUT/project.json" --project "$OUT" > "$OUT/project-generation.log" 2>&1
limit 1200 xcodebuild -project "$OUT/SDKDeviceQA.xcodeproj" -scheme SDKDeviceProbe \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/DerivedData" -allowProvisioningUpdates build > "$OUT/build.log" 2>&1
APP="$OUT/DerivedData/Build/Products/Debug-iphoneos/SDKDeviceProbe.app"
limit 30 codesign --verify --strict "$APP" > "$OUT/signature-check.log" 2>&1
limit 30 codesign -d --entitlements :- "$APP" \
  > "$OUT/signed-entitlements.plist" 2> "$OUT/entitlements-read.log"
limit 30 security cms -D -i "$APP/embedded.mobileprovision" \
  -o "$OUT/decoded-profile.plist" > "$OUT/profile-decode.log" 2>&1

python3 - "$OUT" "$APP" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path.cwd()
out, app = map(Path, sys.argv[1:])
start = json.loads((out / 'source-build-start.json').read_text())
scope = ['Sources/VoIPSDK', 'Sources/VoIPPlatform', 'discovery/device/SDKDeviceProbe.swift',
         'discovery/device/DeviceQAStorage.swift', 'discovery/device/build_sdk.sh']
dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--', *scope], cwd=root)
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
if dirty or commit != start['sourceCommit']:
    raise SystemExit('SDK device build sources changed during compilation.')
combined = hashlib.sha256()
for row in start['inputs']:
    data = (root / row['path']).read_bytes()
    if hashlib.sha256(data).hexdigest() != row['sha256']:
        raise SystemExit('SDK device build input bytes changed during compilation.')
    combined.update(row['path'].encode() + b'\0' + data + b'\0')
if combined.hexdigest() != start['sourceInputsSHA256']:
    raise SystemExit('SDK device build input identity changed during compilation.')
info = plistlib.loads((app / 'Info.plist').read_bytes())
if (info.get('SDKDeviceQASourceCommit'), info.get('SDKDeviceQASourceInputsSHA256')) != (
        start['sourceCommit'], start['sourceInputsSHA256']):
    raise SystemExit('Built app metadata does not match the SDK source identity.')
profile = plistlib.loads((out / 'decoded-profile.plist').read_bytes())
entitlements = profile.get('Entitlements', {})
team, bundle = os.environ['SDK_DEVICE_TEAM_ID'], os.environ['SDK_DEVICE_BUNDLE_ID']
prefixes = profile.get('ApplicationIdentifierPrefix', [])
if (entitlements.get('aps-environment') != 'development' or
        entitlements.get('com.apple.developer.team-identifier') != team or
        team not in profile.get('TeamIdentifier', []) or
        not isinstance(prefixes, list) or not prefixes or
        entitlements.get('application-identifier') not in [prefix + '.' + bundle for prefix in prefixes
                                                        if isinstance(prefix, str) and prefix] or
        info.get('CFBundleIdentifier') != bundle):
    raise SystemExit('Built profile must match the requested development APNs identity.')
signed = plistlib.loads((out / 'signed-entitlements.plist').read_bytes())
if (signed.get('aps-environment') != 'development' or
        signed.get('com.apple.developer.team-identifier') != team or
        signed.get('application-identifier') != entitlements['application-identifier']):
    raise SystemExit('Signed app entitlements must match the development APNs identity.')
def digest(path):
    data = path.read_bytes()
    if not data:
        raise SystemExit('Built app evidence must be nonempty.')
    return hashlib.sha256(data).hexdigest()
receipt = dict(schemaVersion=1, sourceCommit=commit, sourceInputsSHA256=start['sourceInputsSHA256'],
               binarySHA256=digest(app / 'SDKDeviceProbe'),
               provisioningProfileSHA256=digest(app / 'embedded.mobileprovision'),
               signedEntitlementsSHA256=digest(out / 'signed-entitlements.plist'),
               configuration='Debug', platform='iphoneos', destination='generic/platform=iOS',
               developmentAPNs=True, installed=False, launched=False)
(out / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
printf 'SDK device QA app built with a development APNs profile; no install or launch was performed.\n'
