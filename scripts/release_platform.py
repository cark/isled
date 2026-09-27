"""Native build settings and inspection of release binary platform requirements."""

import os
from pathlib import Path
import platform
import re
import subprocess

from release_metadata import TARGETS


def build_environment(target, root):
    expected = TARGETS[target]
    if platform.system() != expected["system"] or platform.machine().lower() != expected["machine"]:
        raise ValueError(f"{target} must be built and tested on its native runner")
    env = os.environ.copy()
    # Own these settings so a local target-cpu=native cannot leak into a release.
    for key in ("CARGO_ENCODED_RUSTFLAGS", "CARGO_BUILD_RUSTFLAGS", "RUSTFLAGS", "CFLAGS", "CXXFLAGS"):
        env.pop(key, None)
    env["CARGO_BUILD_TARGET"] = target
    env["CARGO_TARGET_DIR"] = str(root / "target")
    env["RUSTFLAGS"] = "-C target-cpu=x86-64" if expected["machine"] != "arm64" else ""
    if target.endswith("windows-msvc"):
        env["RUSTFLAGS"] += " -C target-feature=+crt-static"
    elif target.endswith("linux-musl"):
        env["CC_x86_64_unknown_linux_musl"] = "musl-gcc"
        env["CFLAGS_x86_64_unknown_linux_musl"] = "-march=x86-64 -mtune=generic"
    else:
        env["MACOSX_DEPLOYMENT_TARGET"] = "15.0"
        env["CFLAGS_aarch64_apple_darwin"] = "-mmacosx-version-min=15.0"
    return env


def inspect_binary(program, target):
    report = {"system": platform.platform(), "machine": platform.machine(), "commands": []}
    def inspect(*args, allowed=(0,), env=None):
        result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=60, env=env)
        text = result.stdout + result.stderr
        report["commands"].append({"command": [str(arg) for arg in args], "exit": result.returncode, "output": text})
        if result.returncode not in allowed:
            raise ValueError(f"Inspection failed: {args[0]}\n{text}")
        return text
    if target.endswith("linux-musl"):
        headers = inspect("readelf", "--file-header", "--program-headers", "--dynamic", "--notes", program)
        if re.search(r"\bINTERP\b|\(NEEDED\)", headers):
            raise ValueError("Linux executable requires a dynamic loader or shared library")
        if "Advanced Micro Devices X86-64" not in headers:
            raise ValueError("Expected an x86-64 ELF executable")
        report["distribution"] = "Static musl and bundled SQLite; Linux 5.4 is an untested compatibility target."
    elif target.endswith("apple-darwin"):
        libraries = inspect("otool", "-L", program)
        paths = re.findall(r"^\s+(\S+) \(", libraries, re.MULTILINE)
        if not paths or any(not path.startswith(("/usr/lib/", "/System/Library/")) or "sqlite" in path.lower() for path in paths):
            raise ValueError("macOS executable needs a non-system library or external SQLite")
        headers = inspect("otool", "-l", program)
        if not re.search(r"\bminos 15\.0\b", headers):
            raise ValueError("Expected macOS deployment target 15.0")
        inspect("codesign", "--verify", "--strict", program)
        inspect("codesign", "--display", "--verbose=4", program)
        inspect("spctl", "--assess", "--type", "execute", "--verbose=4", program, allowed=(0, 1, 3))
        report["distribution"] = "Ad-hoc linker signature; no Developer ID or notarization. Gatekeeper assessment is recorded; browser-quarantined installation is not established."
    else:
        vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
        installation = inspect(vswhere, "-latest", "-products", "*", "-requires",
                               "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath").strip()
        tools = sorted((Path(installation) / "VC/Tools/MSVC").glob("*/bin/Hostx64/x64/dumpbin.exe"))
        if not tools:
            raise ValueError("MSVC dumpbin not found")
        headers = inspect(tools[-1], "/HEADERS", "/DEPENDENTS", "/IMPORTS", program)
        if "8664 machine (x64)" not in headers:
            raise ValueError("Expected an x86-64 PE executable")
        if re.search(r"(?:VCRUNTIME|MSVCP|MSVCR\d|sqlite3)\S*\.dll", headers, re.IGNORECASE):
            raise ValueError("Windows executable requires an extra runtime or SQLite DLL")
        versions = re.findall(r"(\d+)\.(\d+)\s+(?:operating system|subsystem) version", headers)
        if not versions or any(tuple(map(int, version)) > (10, 0) for version in versions):
            raise ValueError("PE headers require a system newer than Windows 10")
        # Reading Authenticode state does not install or execute the artifact.
        inspect("powershell", "-NoProfile", "-NonInteractive", "-Command",
                "Get-AuthenticodeSignature -LiteralPath $env:ISLED_RELEASE_INSPECT_PROGRAM | Format-List Status,StatusMessage",
                env={**os.environ, "ISLED_RELEASE_INSPECT_PROGRAM": str(program)})
        report["distribution"] = "Static MSVC CRT and bundled SQLite; no publisher signature. Windows 10 and desktop SmartScreen behavior remain untested."
    return report
