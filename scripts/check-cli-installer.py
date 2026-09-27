#!/usr/bin/env python3
"""Install a candidate Emacs package and provision a real staged CLI in isolation."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import runpy
import shutil
import subprocess
import threading
import time
from urllib.parse import urlparse

from release_metadata import TARGETS, sha256, write_json

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('package', 'artifacts', 'dependencies', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--upgrade', type=Path, help='Complete verified version-only upgrade candidate')
    parser.add_argument('--emacs', default='emacs')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    verify = runpy.run_path(str(root / 'scripts/stage-release.py'))['verify']
    manifest = verify(args.artifacts)
    upgrade = verify(args.upgrade) if args.upgrade else None
    if upgrade and upgrade['version'] == manifest['version']:
        raise ValueError('Upgrade must have a different CLI version')
    target = next(name for name, spec in TARGETS.items()
                  if (platform.system(), platform.machine().lower()) == (spec['system'], spec['machine']))
    editor = shutil.which(args.emacs)
    if not editor:
        raise ValueError('Cannot locate the acceptance editor')
    security = None
    if platform.system() == 'Darwin':
        security = subprocess.check_output(['spctl', '--status'], text=True, stderr=subprocess.STDOUT).strip()
        if security != 'assessments enabled':
            raise ValueError('Native macOS acceptance requires normal enabled Gatekeeper assessment: ' + security)
    args.output.mkdir(parents=True, exist_ok=False)
    empty_path = args.output.resolve() / 'empty-path'
    empty_path.mkdir()
    assets = {path.name: path for directory in (args.artifacts, args.upgrade) if directory
              for path in directory.iterdir()}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            pass

        def do_GET(self):
            mode, _, name = urlparse(self.path).path.lstrip('/').partition('/')
            path = assets.get(name)
            if mode == 'missing' or not path:
                self.send_error(404)
                return
            if mode == 'cancel':
                time.sleep(1)  # Let the editor cancel a genuinely pending request.
            content = path.read_bytes()
            archive = name.endswith(('.tar.gz', '.zip'))
            size = len(content)
            if mode == 'corrupt' and archive:
                content = bytes([content[0] ^ 1]) + content[1:]
            if mode == 'interrupted' and archive:
                content = content[:len(content) // 2]
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(size))
            self.end_headers()
            try:
                self.wfile.write(content)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass  # Expected when the editor cancels a request.

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = dict(os.environ, PATH=str(empty_path), ISLED_INSTALL_CHECK_DIR=str(args.output.resolve()),
               ISLED_INSTALL_TEST_ORIGIN=f'http://127.0.0.1:{server.server_port}',
               ISLED_PACKAGE_ARCHIVE=str(args.package.resolve()),
               ISLED_INSTALL_BASE_VERSION=manifest['version'],
               ISLED_CHECK_PACKAGE_DIR=str(args.dependencies.resolve()))
    modes = ['decline', 'missing', 'cancel', 'install', 'offline', 'explicit', 'unsupported']
    if upgrade:
        modes += ['corrupt', 'interrupted', 'upgrade', 'rollback', 'mismatch']
    try:
        for mode in modes:
            env['ISLED_INSTALL_CHECK_MODE'] = mode
            upgraded = mode in ('corrupt', 'interrupted', 'upgrade', 'mismatch')
            env['ISLED_PACKAGE_ARCHIVE'] = str((args.upgrade / upgrade['emacs']['name']).resolve()
                                             if upgraded else args.package.resolve())
            with (args.output / (mode + '.log')).open('w') as log:
                subprocess.run([editor, '-Q', '--batch', '-l',
                                str(root / 'frontends/emacs/test/cli-install-staged.el')],
                               env=env, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=180)
        receipt = {'result': 'passed', 'cli': manifest['version'],
                   'artifact_revision': manifest['revision'],
                   'upgrade_revision': upgrade['revision'] if upgrade else None,
                   'upgrade_cli': upgrade['version'] if upgrade else None,
                   'target': target, 'platform': platform.platform(),
                   'macos_assessment': security,
                   'package_sha256': sha256(args.package), 'output': str(args.output),
                   'checks': modes, 'compiler_and_cli_path': 'empty'}
        write_json(args.output / 'receipt.json', receipt)
        print(json.dumps(receipt))
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


if __name__ == '__main__':
    main()
