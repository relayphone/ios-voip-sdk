#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?Provide a fresh output directory}
[[ ! -e "$OUT" ]] || { echo "Output already exists: $OUT" >&2; exit 1; }
OUT=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT")
VERSION=$(cat VERSION)
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "Invalid runtime VERSION" >&2; exit 1; }
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
METADATA=0
[[ ! -f "$SDK/System/Library/Frameworks/PushKit.framework/Headers/PKVoIPPushMetadata.h" ]] || METADATA=1
ARCHS=${CKSIM_BUILD_ARCHS:-"arm64 x86_64"}
WORK=$(mktemp -d "$(dirname "$OUT")/.cksim-runtime-build.XXXXXX")
PACKAGE="$WORK/package"
mkdir "$PACKAGE"
trap 'rm -rf "$WORK"' EXIT
for arch in $ARCHS; do
  target="$arch-apple-ios18.0-simulator"
  for source in CKInterposition CKPushDelivery CKPushLaunch; do
    xcrun --sdk iphonesimulator clang -target "$target" -isysroot "$SDK" -fobjc-arc -fmodules -DCKSIM_RUNTIME_VERSION=\""$VERSION"\" -DCKSIM_HAS_VOIP_METADATA="$METADATA" -DCKSIM_ABI_TESTING="${CKSIM_ABI_TESTING:-0}" \
      -c "Sources/Interposition/$source.m" -o "$WORK/$source-$arch.o"
  done
  xcrun --sdk iphonesimulator swiftc -target "$target" -sdk "$SDK" -swift-version 6 -O -emit-library -module-name CKSimRuntime \
    -import-objc-header Sources/Interposition/CKRuntimeSeam.h Sources/CKSimProtocol/*.swift Sources/Engine/RuntimeEngine.swift \
    "$WORK/CKInterposition-$arch.o" "$WORK/CKPushDelivery-$arch.o" "$WORK/CKPushLaunch-$arch.o" \
    -Xlinker -install_name -Xlinker @rpath/CKSimRuntime.dylib -o "$WORK/CKSimRuntime-$arch.dylib"
  xcrun --sdk iphonesimulator clang -target "$target" -isysroot "$SDK" -fobjc-arc -dynamiclib -framework Foundation \
    Sources/Interposition/CKLoader.m -o "$WORK/CKSimLoader-$arch.dylib"
done
runtime=(); loader=()
for arch in $ARCHS; do runtime+=("$WORK/CKSimRuntime-$arch.dylib"); loader+=("$WORK/CKSimLoader-$arch.dylib"); done
lipo -create "${runtime[@]}" -output "$PACKAGE/CKSimRuntime.dylib"
lipo -create "${loader[@]}" -output "$PACKAGE/CKSimLoader.dylib"
codesign -s - --force "$PACKAGE/CKSimRuntime.dylib"
codesign -s - --force "$PACKAGE/CKSimLoader.dylib"
mkdir "$PACKAGE/profiles"
cp Sources/Engine/Resources/*.json "$PACKAGE/profiles/"
cp Tools/cksim "$PACKAGE/cksim"
cp VERSION "$PACKAGE/VERSION"
cp docs/simulator-runtime.md "$PACKAGE/README.md"
chmod +x "$PACKAGE/cksim"
python3 - "$PACKAGE" "$SDK" "$ARCHS" "$VERSION" "${CKSIM_ABI_TESTING:-0}" <<'PYINFO'
import hashlib,json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
inputs=[pathlib.Path('VERSION'), pathlib.Path('docs/simulator-runtime.md')] + [p for folder in ('Sources','Tools','scripts') for p in pathlib.Path(folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
source_hash=hashlib.sha256()
for p in sorted(inputs):
    source_hash.update(str(p).encode()+b'\0'+p.read_bytes()+b'\0')
files={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
def output(*args):
    return subprocess.check_output(args, text=True).strip()
info=dict(schemaVersion=1,version=sys.argv[4],profile='ios-27.0',sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
          sourceDirty=bool(subprocess.check_output(['git','status','--porcelain'],text=True)),sourceInputsSHA256=source_hash.hexdigest(),
          sourceDateEpoch=int(output('git', 'show', '-s', '--format=%ct', 'HEAD')),
          toolchain=dict(xcode=output('xcodebuild', '-version'), swift=output('xcrun', 'swiftc', '--version'),
                         clang=output('xcrun', 'clang', '--version')),
          sdk=dict(version=output('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'),
                   build=output('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-build-version')),
          sdkPath=sys.argv[2],architectures=sys.argv[3].split(),abiTesting=sys.argv[5]=='1',files=files)
(root/'build-info.json').write_text(json.dumps(info,indent=2,sort_keys=True)+'\n')
PYINFO
mv "$PACKAGE" "$OUT"
