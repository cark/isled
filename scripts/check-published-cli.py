#!/usr/bin/env python3
"""Verify anonymous release delivery and test the frontend against its published CLI pin."""

import argparse
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
from urllib.request import urlopen

from release_metadata import REPOSITORY, TARGETS, checksums_name, manifest_name, match_one

ROOT = Path(__file__).resolve().parent.parent


def download(directory, version, name):
    """Fetch one bounded, anonymous HTTPS asset into the private check directory."""
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name):
        raise ValueError('Unsafe release asset name')
    url = f'https://github.com/{REPOSITORY}/releases/download/v{version}/{name}'
    limit = 128 * 1024 * 1024
    with urlopen(url, timeout=120) as response:
        if not response.url.startswith('https://'):
            raise ValueError('Release download left HTTPS')
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Release asset exceeds the check limit')
    (directory / name).write_bytes(data)
    print(f'Downloaded anonymously: {name}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dependencies', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New private output directory')
    parser.add_argument('--emacs', default='emacs')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.dependencies = args.dependencies.resolve()
    pin = match_one(r'\(defconst isled-required-cli-version "([0-9]+\.[0-9]+\.[0-9]+)"',
                    (ROOT / 'frontends/emacs/isled.el').read_text(encoding='utf-8'), 'CLI pin')
    artifacts = args.output / 'artifacts'
    artifacts.mkdir(parents=True, exist_ok=False)
    names = [manifest_name(pin), checksums_name(pin), f'isled-{pin}.tar']
    for target in TARGETS:
        names += [f'isled-{pin}-{target}.build.json',
                  f'isled-{pin}-{target}' + ('.zip' if target.endswith('windows-msvc') else '.tar.gz')]
    for name in names:
        download(artifacts, pin, name)
    manifest = runpy.run_path(str(ROOT / 'scripts/stage-release.py'))['verify'](artifacts)
    if manifest['version'] != pin:
        raise ValueError('Published release does not match the frontend CLI pin')
    install = args.output / 'install'
    subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/check-cli-installer.py'), '--live',
                    '--package', str(artifacts / manifest['emacs']['name']),
                    '--artifacts', str(artifacts), '--dependencies', str(args.dependencies),
                    '--output', str(install), '--emacs', args.emacs], check=True, timeout=1000)
    receipt = json.loads((install / 'receipt.json').read_text(encoding='utf-8'))
    environment = dict(os.environ, ISLED_CHECK_PACKAGE_DIR=str(args.dependencies),
                       ISLED_CHECK_PROGRAM=receipt['program'], ISLED_CHECK_PHASE='tests')
    with (args.output / 'frontend.log').open('w', encoding='utf-8') as log:
        subprocess.run([args.emacs, '-Q', '--batch', '-l', 'frontends/emacs/test/run-check.el'],
                       cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=600)
    print(f'Published CLI {pin}: anonymous assets, managed first use, offline reuse and frontend suite passed')


if __name__ == '__main__':
    main()
