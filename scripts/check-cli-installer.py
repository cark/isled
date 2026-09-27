#!/usr/bin/env python3
"""Install a candidate Emacs package and provision a real staged CLI in isolation."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import subprocess
import threading

from release_metadata import sha256, write_json

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('package', 'artifacts', 'dependencies', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--emacs', default='emacs')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    manifest = runpy.run_path(str(root / 'scripts/stage-release.py'))['verify'](args.artifacts)
    args.output.mkdir(parents=True, exist_ok=False)

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, _format, *_args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(args.artifacts.resolve())))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = dict(os.environ, ISLED_INSTALL_CHECK_DIR=str(args.output.resolve()),
               ISLED_INSTALL_TEST_ORIGIN=f'http://127.0.0.1:{server.server_port}',
               ISLED_PACKAGE_ARCHIVE=str(args.package.resolve()),
               ISLED_CHECK_PACKAGE_DIR=str(args.dependencies.resolve()))
    try:
        for mode in ('install', 'offline'):
            env['ISLED_INSTALL_CHECK_MODE'] = mode
            with (args.output / (mode + '.log')).open('w') as log:
                subprocess.run([args.emacs, '-Q', '--batch', '-l',
                                str(root / 'frontends/emacs/test/cli-install-staged.el')],
                               env=env, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=180)
        receipt = {'result': 'passed', 'cli': manifest['version'],
                   'artifact_revision': manifest['revision'],
                   'package_sha256': sha256(args.package), 'output': str(args.output),
                   'checks': ['first-use', 'offline-after-package-replacement']}
        write_json(args.output / 'receipt.json', receipt)
        print(json.dumps(receipt))
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


if __name__ == '__main__':
    main()
