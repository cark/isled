"""Write and verify complete executable-and-skill release bundles."""

import gzip
import hashlib
import io
import json
import tarfile
import zipfile

from release_metadata import TARGETS, archive_name, asset, verify_asset

SKILL_FILES = ('SKILL.md', 'references/mutations.md', 'references/recovery.md')


def descriptor(name, content):
    return {'name': name, 'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()}


def pack_cli(directory, version, target, executable, license_file, skill_directory):
    path = directory / archive_name(version, target)
    prefix = f'isled-{version}-{target}'
    program = TARGETS[target]['executable']
    supplied = {path.relative_to(skill_directory).as_posix() for path in skill_directory.rglob('*')
                if path.is_file() or path.is_symlink()}
    if supplied != set(SKILL_FILES):
        raise ValueError('Skill contents changed; update the complete bundle contract before packaging')
    sources = {program: executable, 'LICENSE': license_file,
               **{'skill/' + name: skill_directory / name for name in SKILL_FILES}}
    if any(source.is_symlink() or not source.is_file() for source in sources.values()):
        raise ValueError('Missing or non-regular release bundle file')
    contents = {name: source.read_bytes() for name, source in sources.items()}
    bundle = {'schema_version': 1, 'version': version, 'target': target,
              'files': [descriptor(name, contents[name]) for name in sorted(contents)]}
    contents['bundle.json'] = (json.dumps(bundle, indent=2, sort_keys=True) + '\n').encode('utf-8')
    entries = [(prefix + '/' + name, content, 0o755 if name == program else 0o644)
               for name, content in sorted(contents.items())]
    if path.suffix == '.zip':
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, content, mode in entries:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (0o100000 | mode) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, content)
    else:
        pack_tar(path, entries)
    def member(name):
        item = descriptor(prefix + '/' + name, contents[name])
        item['member'] = item.pop('name')
        return item
    return {'archive': asset(path), 'executable': member(program), 'bundle': member('bundle.json')}


def pack_tar(path, entries):
    with path.open('wb') as output:
        with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name, content, mode in entries:
                    entry = tarfile.TarInfo(name)
                    entry.size, entry.mode, entry.mtime = len(content), mode, 0
                    archive.addfile(entry, io.BytesIO(content))


def unpack_cli(directory, release, version, target, destination):
    path = verify_asset(directory, release['archive'])
    if path.name != archive_name(version, target):
        raise ValueError('Unexpected target archive name')
    prefix = f'isled-{version}-{target}/'
    program = TARGETS[target]['executable']
    names = {prefix + name for name in (program, 'LICENSE', 'bundle.json')}
    names.update(prefix + 'skill/' + name for name in SKILL_FILES)
    contents = read_zip(path, names) if path.suffix == '.zip' else read_tar(path, names)
    for key, name in [('executable', program), ('bundle', 'bundle.json')]:
        item = dict(release[key])
        if item.pop('member') != prefix + name or descriptor('', contents[prefix + name]) != {'name': '', **item}:
            raise ValueError(f'{key.capitalize()} checksum mismatch')
    bundle = json.loads(contents[prefix + 'bundle.json'])
    files = bundle['files']
    if (bundle['schema_version'], bundle['version'], bundle['target']) != (1, version, target):
        raise ValueError('Bundle identity mismatch')
    expected = {name.removeprefix(prefix) for name in names} - {'bundle.json'}
    if len(files) != len(expected) or {item['name'] for item in files} != expected:
        raise ValueError('Incomplete or duplicate bundle files')
    for item in files:
        if descriptor(item['name'], contents[prefix + item['name']]) != item:
            raise ValueError('Bundle file checksum mismatch')
    # Only write explicitly verified members. No extractall or path guessing.
    destination.mkdir(parents=True, exist_ok=True)
    for name, content in contents.items():
        output = destination / name.removeprefix(prefix)
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open('xb') as stream:
            stream.write(content)
    output = destination / program
    output.chmod(0o755)
    return output.resolve()


def read_zip(path, names):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if {entry.filename for entry in entries} != names or len(entries) != len(names):
            raise ValueError('Unexpected CLI archive contents')
        if any(entry.is_dir() or (entry.external_attr >> 16) & 0o170000 != 0o100000 for entry in entries):
            raise ValueError('CLI archive contains a link or special file')
        if any(entry.file_size > 128 * 1024 * 1024 for entry in entries):
            raise ValueError('Oversized bundle file')
        return {entry.filename: archive.read(entry) for entry in entries}


def read_tar(path, names):
    with tarfile.open(path, 'r:gz') as archive:
        entries = archive.getmembers()
        if {entry.name for entry in entries} != names or len(entries) != len(names):
            raise ValueError('Unexpected CLI archive contents')
        if any(not entry.isfile() for entry in entries):
            raise ValueError('CLI archive contains a link or special file')
        if any(entry.size > 128 * 1024 * 1024 for entry in entries):
            raise ValueError('Oversized bundle file')
        return {entry.name: archive.extractfile(entry).read() for entry in entries}
