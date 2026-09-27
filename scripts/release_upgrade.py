#!/usr/bin/env python3
"""Create an isolated, reproducible next-version source for upgrade acceptance."""

import argparse
import os
from pathlib import Path
import re
import subprocess

from release_metadata import capture, release_version, source_revision


def prepare(root, destination, revision):
    """Commit version-only changes in a disposable Git repository, never ROOT."""
    revision = source_revision(root, revision)
    version = release_version(root)
    parts = version.split('.')
    parts[-1] = str(int(parts[-1]) + 1)
    following = '.'.join(parts)
    destination.mkdir(parents=True, exist_ok=False)

    def git(*args, env=None):
        subprocess.run(['git', '-c', 'core.autocrlf=false', *args], cwd=destination,
                       env=env, check=True)

    git('init', '--quiet')
    # Actions checks out a shallow source; retain that boundary in the fixture.
    git('fetch', '--quiet', '--update-shallow', str(root), revision)
    git('checkout', '--quiet', '-b', 'upgrade-fixture', 'FETCH_HEAD')
    edits = {
        'Cargo.toml': [(r'(^version = ")[^"]+("$)', 1)],
        'Cargo.lock': [(r'(name = "isled"\nversion = ")[^"]+(")', 1)],
        'flake.nix': [(r'(pname = "isled";\s+version = ")[^"]+(")', 1)],
        'frontends/emacs/isled.el': [(r'(^;; Version: )[^\n]+($)', 1),
                                    (r'(\(defconst isled-required-cli-version ")[^"]+(")', 1)],
    }
    for name, replacements in edits.items():
        path = destination / name
        text = path.read_text(encoding='utf-8')
        for pattern, expected in replacements:
            text, count = re.subn(pattern, lambda m: m[1] + following + m[2], text, flags=re.M)
            if count != expected:
                raise ValueError(f'Unexpected version declarations in {name}')
        path.write_bytes(text.encode('utf-8'))
    # Identical source/version fixtures on all three runners must have one identity.
    timestamp = str(int(capture('git', 'show', '-s', '--format=%ct', revision, cwd=root)) + 60)
    env = dict(os.environ, GIT_AUTHOR_NAME='Isled acceptance fixture',
               GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Isled acceptance fixture',
               GIT_COMMITTER_EMAIL='fixture@example.invalid',
               GIT_AUTHOR_DATE=timestamp + ' +0000', GIT_COMMITTER_DATE=timestamp + ' +0000')
    git('add', *edits)
    git('-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Version-only upgrade acceptance fixture', env=env)
    if release_version(destination) != following:
        raise ValueError('Upgrade fixture version mismatch')
    print(f'Upgrade fixture {following}: {capture("git", "rev-parse", "HEAD", cwd=destination)}')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', default='HEAD')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(Path(__file__).resolve().parent.parent, args.output.resolve(), args.revision)


if __name__ == '__main__':
    main()
