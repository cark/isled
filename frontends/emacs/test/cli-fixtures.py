"""Create disposable installer fixtures with the real release archive writer."""

import io
import json
from pathlib import Path
import sys
import tarfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts'))
from release_archive import pack_cli
from release_metadata import TARGETS, asset, write_json

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
license_file = root / 'LICENSE'
license_file.write_text('Installer test license\n')
for version in ('0.32.0', '0.32.1'):
    directory = root / version
    directory.mkdir()
    executable = root / 'fixture-program'
    executable.write_bytes(('isled ' + version + '\n').encode())
    skill = Path(__file__).resolve().parents[3] / 'skills/isled'
    binaries = {target: pack_cli(directory, version, target, executable, license_file, skill) for target in TARGETS}
    manifest = directory / f'isled-{version}-manifest.json'
    write_json(manifest, {'schema_version': 2, 'repository': 'cark/isled', 'version': version,
                          'tag': 'v' + version, 'binaries': binaries})
    files = sorted(directory.iterdir())
    (directory / f'isled-{version}-SHA256SUMS').write_text(
        ''.join(f'{asset(path)["sha256"]}  {path.name}\n' for path in files))

prefix = 'isled-0.32.0-x86_64-unknown-linux-musl/'
for kind in ('traversal', 'symlink', 'duplicate', 'extra'):
    with tarfile.open(root / (kind + '.tar.gz'), 'w:gz', format=tarfile.USTAR_FORMAT) as archive:
        for index, name in enumerate([prefix + 'isled', prefix + 'LICENSE']):
            entry = tarfile.TarInfo('../escape' if kind == 'traversal' and index == 0 else name)
            if kind == 'duplicate' and index == 1:
                entry.name = prefix + 'isled'
            if kind == 'symlink' and index == 0:
                entry.type = tarfile.SYMTYPE
                entry.linkname = '../escape'
            else:
                entry.size = 2
            archive.addfile(entry, io.BytesIO(b'ok'))
        if kind == 'extra':
            archive.addfile(tarfile.TarInfo('extra'))

with zipfile.ZipFile(root / 'symlink.zip', 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for name in ('isled.exe', 'LICENSE'):
        entry = zipfile.ZipInfo('isled-0.32.0-x86_64-pc-windows-msvc/' + name)
        entry.create_system = 3
        entry.external_attr = (0o120777 if name == 'isled.exe' else 0o100644) << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(entry, b'../escape')
