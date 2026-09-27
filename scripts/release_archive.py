"""Write and safely extract the two-member CLI release archive."""

import gzip
import hashlib
import io
import tarfile
import zipfile

from release_metadata import TARGETS, archive_name, asset, verify_asset


def pack_cli(directory, version, target, executable, license_file):
    path = directory / archive_name(version, target)
    prefix = f"isled-{version}-{target}"
    member = prefix + "/" + TARGETS[target]["executable"]
    sources = [(member, executable, 0o755), (prefix + "/LICENSE", license_file, 0o644)]
    if path.suffix == ".zip":
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, source, mode in sources:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (0o100000 | mode) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, source.read_bytes())
    else:
        pack_tar(path, sources)
    return {"archive": asset(path), "executable": {"member": member, "size": executable.stat().st_size,
            "sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}}


def pack_tar(path, sources):
    with path.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for name, source, mode in sources:
                    content = source.read_bytes()
                    entry = tarfile.TarInfo(name)
                    entry.size, entry.mode, entry.mtime = len(content), mode, 0
                    archive.addfile(entry, io.BytesIO(content))


def unpack_cli(directory, descriptor, version, target, destination):
    # Verify the compressed file first. No extraction or binary execution precedes it.
    path = verify_asset(directory, descriptor["archive"])
    expected = archive_name(version, target)
    if path.name != expected:
        raise ValueError("Unexpected target archive name")
    prefix = f"isled-{version}-{target}"
    member = prefix + "/" + TARGETS[target]["executable"]
    if descriptor["executable"]["member"] != member:
        raise ValueError("Unexpected executable member")
    names = {member, prefix + "/LICENSE"}
    size = descriptor["executable"]["size"]
    content = read_zip(path, names, member, size) if path.suffix == ".zip" else read_tar(path, names, member, size)
    if hashlib.sha256(content).hexdigest() != descriptor["executable"]["sha256"]:
        raise ValueError("Executable checksum mismatch")
    # Write only the verified, explicitly named member; never extractall.
    destination.mkdir(parents=True, exist_ok=True)
    program = destination / TARGETS[target]["executable"]
    with program.open("xb") as output:
        output.write(content)
    program.chmod(0o755)
    return program.resolve()


def read_zip(path, names, member, size):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if {entry.filename for entry in entries} != names or len(entries) != 2:
            raise ValueError("Unexpected CLI archive contents")
        if any(entry.is_dir() or (entry.external_attr >> 16) & 0o170000 != 0o100000 for entry in entries):
            raise ValueError("CLI archive contains a link or special file")
        if archive.getinfo(member).file_size != size:
            raise ValueError("Executable size mismatch")
        return archive.read(member)


def read_tar(path, names, member, size):
    with tarfile.open(path, "r:gz") as archive:
        entries = archive.getmembers()
        if {entry.name for entry in entries} != names or len(entries) != 2:
            raise ValueError("Unexpected CLI archive contents")
        if any(not entry.isfile() for entry in entries):
            raise ValueError("CLI archive contains a link or special file")
        entry = archive.getmember(member)
        if entry.size != size:
            raise ValueError("Executable size mismatch")
        return archive.extractfile(entry).read()
