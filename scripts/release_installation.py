"""Exercise standalone bundle installation with native, extracted executables."""

import json
import os
from pathlib import Path
import subprocess

from release_archive import SKILL_FILES, unpack_cli
from release_metadata import sha256


def check_installation(program, root, version, env):
    """Install, inspect and execute through current; check the whole selected bundle."""
    def run(*arguments):
        return subprocess.check_output([str(program), *map(str, arguments)], env=env,
                                       text=True, encoding='utf-8', timeout=60)
    paths = json.loads(run('install', '--directory', root, '--json'))
    if paths != json.loads(run('installation', '--directory', root, '--json')):
        raise ValueError('Installation and later path discovery disagree')
    expected = {'executable': root / 'current' / program.name,
                'skill': root / 'current/skill', 'skill_file': root / 'current/skill/SKILL.md',
                'path_directory': root / 'current',
                'program': root / 'versions' / version / program.name}
    if paths['schema_version'] != 1 or paths['version'] != version or Path(paths['root']) != root:
        raise ValueError('Unexpected installation identity')
    if any(Path(paths[key]) != value for key, value in expected.items()):
        raise ValueError('Installer did not preserve stable current paths and exact version path')
    selected = root / 'current'
    for name in (program.name, 'LICENSE', 'bundle.json', *('skill/' + name for name in SKILL_FILES)):
        if sha256(selected / name) != sha256(program.parent / name):
            raise ValueError('Executable and skill were not activated together: ' + name)
    result = subprocess.check_output([paths['executable'], '--version'], env=env,
                                     text=True, encoding='utf-8', timeout=30).strip()
    if result != 'isled ' + version:
        raise ValueError('Current executable reports the wrong version')
    human = run('installation', '--directory', root)
    if any(str(expected[key]) not in human for key in ('executable', 'skill', 'skill_file', 'path_directory')):
        raise ValueError('Human output omits a stable installation path')
    return paths


def check_standalone(artifacts, manifest, upgrade, following, target, output):
    """Check native upgrade and rollback while the old executable remains running."""
    root = output.resolve() / 'standalone storage é'
    env = dict(os.environ, PATH=str(output.resolve() / 'empty-path'))
    program = unpack_cli(artifacts, manifest['binaries'][target], manifest['version'],
                         target, output / 'standalone-base')
    paths = check_installation(program, root, manifest['version'], env)
    if following:
        next_program = unpack_cli(upgrade, following['binaries'][target], following['version'],
                                  target, output / 'standalone-upgrade')
        with subprocess.Popen([paths['program'], '--root', str(output / 'absent-ledger'),
                               'frontend', '--stdin'], env=env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as held:
            try:
                paths = check_installation(next_program, root, following['version'], env)
                if held.poll() is not None:
                    raise ValueError('Upgrade interrupted the previous executable')
                paths = check_installation(program, root, manifest['version'], env)
                # A failed reinstall must leave the selected executable and skill intact.
                skill = next_program.parent / 'skill/SKILL.md'
                skill.write_bytes(skill.read_bytes() + b'corrupt')
                failed = subprocess.run([str(next_program), 'install', '--directory', str(root)],
                                        env=env, capture_output=True, timeout=60)
                if failed.returncode == 0:
                    raise ValueError('Installer accepted a damaged skill')
                paths = check_installation(program, root, manifest['version'], env)
            finally:
                held.communicate(input=b'', timeout=30)
    if (output / 'absent-ledger').exists():
        raise ValueError('Installer or held process created a ledger')
    return {'result': 'passed', 'version': manifest['version'],
            'upgrade': following['version'] if following else None,
            'paths': paths, 'path': 'empty'}
