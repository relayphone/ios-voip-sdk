#!/bin/bash
set -euo pipefail
DIST=$(cd "${1:?pass a complete runtime distribution}" && pwd)
OUT=${2:?pass a fresh artifact directory}
mkdir "$OUT"
OUT=$(cd "$OUT" && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$DIST" "$OUT" <<'PY'
import gzip,hashlib,importlib.machinery,importlib.util,json,pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2])
loader=importlib.machinery.SourceFileLoader('cksim',str(root/'cksim'))
spec=importlib.util.spec_from_loader('cksim',loader);module=importlib.util.module_from_spec(spec);loader.exec_module(module)
module.validate_package(root)
info=json.loads((root/'build-info.json').read_text())
epoch=info['sourceDateEpoch']
if type(epoch) is not int or epoch < 0:
    raise ValueError('Invalid source date epoch')
archive=out/f"callkit-simulator-v{info['version']}-macos.tar.gz"
# Normalize archive metadata, not the signed binary bytes. This makes packaging
# the same distribution reproducible; rebuilding Mach-O files is a separate claim.
with archive.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=epoch) as compressed:
    with tarfile.open(fileobj=compressed,mode='w',format=tarfile.USTAR_FORMAT) as tar:
        for path in [root,*sorted(root.rglob('*'))]:
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError(f'Unsupported package entry: {path}')
            name='.' if path == root else './'+path.relative_to(root).as_posix()
            entry=tar.gettarinfo(str(path),arcname=name)
            entry.uid=entry.gid=0;entry.uname=entry.gname='';entry.mtime=epoch
            entry.mode=0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644
            if path.is_file():
                with path.open('rb') as content: tar.addfile(entry,content)
            else: tar.addfile(entry)
(out/'SHA256SUMS').write_text(f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n')
PY
