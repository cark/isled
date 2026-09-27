#!/usr/bin/env python3
"""Exercise public checks against ordinary disposable Git repositories."""
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPTS=Path(__file__).resolve().parent


class ContributorChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='isled checks ')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.git('-c','init.defaultBranch=main','init','--quiet')
        (self.root/'scripts').mkdir()
        for name in ['repository_files.py','check-repository.py','check-coding-standards.py']:
            shutil.copy2(SCRIPTS/name,self.root/'scripts'/name)
        self.write('README.md','# Contributor fixture\n')

    def git(self,*args):
        return subprocess.check_output(['git','-C',str(self.root),*args],stderr=subprocess.STDOUT)

    def write(self,name,text):
        path=self.root/name
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(text.encode('utf-8'))

    def commit(self):
        self.git('add','.')
        self.git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                 '-c','commit.gpgsign=false','commit','--quiet','-m','fixture')

    def run_check(self,name,*args):
        return subprocess.run([sys.executable,'-B',str(self.root/'scripts'/name),*args],
                              cwd=self.root,capture_output=True,text=True)

    def test_initial_commit_and_revision_selection_without_jj(self):
        self.write('src/path with spaces.rs','fn main() {}\n')
        self.commit()
        result=self.run_check('check-coding-standards.py','--revision','HEAD')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('src/path with spaces.rs',result.stdout)
        self.write('src/path with spaces.rs','// organization review\n'*1000)
        self.commit()
        result=self.run_check('check-coding-standards.py','--revision','HEAD')
        self.assertEqual(result.returncode,3,result.stderr)
        self.write('README.md','# Changed documentation\n')
        self.commit()
        self.assertEqual(self.run_check('check-coding-standards.py','--revision','HEAD').returncode,0)
        self.assertEqual(self.run_check('check-coding-standards.py').returncode,3)
        (self.root/'src/path with spaces.rs').unlink()
        self.assertEqual(self.run_check('check-coding-standards.py').returncode,0)
        # The exact whitespace gate used by the maintainer helper accepts a root commit.
        root_commit=self.git('rev-list','--max-parents=0','HEAD').decode().strip()
        self.git('show','--format=','--check',root_commit)

    def test_generated_and_private_files_are_rejected_when_tracked(self):
        self.write('scripts/__pycache__/cached.pyc','generated\n')
        self.write('.codex/config.toml','[agents]\n')
        self.write('research/session.md','Private history\n')
        self.commit()
        result=self.run_check('check-repository.py')
        self.assertEqual(result.returncode,1,result.stderr)
        for path in ['cached.pyc','.codex/config.toml','research/session.md']:
            self.assertIn(path,result.stderr)

    def test_docs_require_tracked_targets_and_real_anchors(self):
        self.write('docs/design.md','# Design\n\n## Repeated\n\n## Repeated\n')
        self.write('README.md','[Design](docs/design.md#repeated-1)\n')
        self.commit()
        self.assertEqual(self.run_check('check-repository.py').returncode,0)
        self.write('docs/private.md','# Private\n')
        self.write('README.md','[Missing heading](docs/design.md#absent)\n[Private](docs/private.md)\n[External](../../private.md)\n')
        result=self.run_check('check-repository.py')
        self.assertEqual(result.returncode,1)
        for expected in ['missing heading','missing/untracked','escapes checkout']:
            self.assertIn(expected,result.stderr)

    def test_examples_are_not_interpreted_as_links_and_paths_are_scoped(self):
        self.write('README.md','```markdown\n[Example](unavailable.md)\n```\n')
        fixture='frontends/emacs/test/isled-header-test.el'
        self.write(fixture,'"/home/'+'me/work/app/"\n')
        self.commit()
        self.assertEqual(self.run_check('check-repository.py').returncode,0)
        self.write(fixture,'"/home/'+'someone/private/"\n')
        result=self.run_check('check-repository.py')
        self.assertEqual(result.returncode,1)
        self.assertIn('concrete workstation path',result.stderr)

    def test_symlink_cannot_read_an_external_dependency(self):
        target=self.root.parent/(self.root.name+'-external')
        target.write_text('external\n')
        self.addCleanup(target.unlink)
        try:
            (self.root/'external').symlink_to(target)
        except OSError as error:
            self.skipTest(f'Symlink creation unavailable: {error}')
        self.commit()
        result=self.run_check('check-repository.py')
        self.assertEqual(result.returncode,1)
        self.assertIn('external local resource',result.stderr)

    def test_symlink_cannot_require_an_untracked_directory(self):
        target = self.root / 'local-state'
        target.mkdir()
        try:
            (self.root / 'linked-state').symlink_to(target, target_is_directory=True)
        except OSError as error:
            self.skipTest(f'Symlink creation unavailable: {error}')
        self.commit()
        result = self.run_check('check-repository.py')
        self.assertEqual(result.returncode, 1)
        self.assertIn('untracked resource', result.stderr)

    def test_source_archive_includes_license_and_no_validation_state(self):
        frontend=self.root/'frontends/emacs'
        frontend.mkdir(parents=True)
        self.write('frontends/emacs/isled-pkg.el','(define-package "isled" "1.2.3" "fixture" nil)\n')
        self.write('frontends/emacs/isled.el',
                   ';;; isled.el --- Fixture  -*- lexical-binding: t; -*-\n'
                   ';; Version: 1.2.3\n;; Package-Requires: ((emacs "30.1"))\n'
                   ';; URL: https://github.com/example/fixture\n;; Keywords: tools\n')
        self.write('frontends/emacs/isled.elc','generated\n')
        self.write('frontends/emacs/README.md','# Fixture\n')
        self.write('frontends/emacs/user-guide.md','# User guide\n')
        self.write('frontends/emacs/CONTRIBUTING.md','# Contributing\n')
        self.write('frontends/emacs/images/hierarchy.gif','GIF89a hierarchy fixture\n')
        self.write('frontends/emacs/images/filtering.gif','GIF89a filtering fixture\n')
        self.write('frontends/emacs/test/private.el','test only\n')
        self.write('LICENSE','MIT fixture\n')
        shutil.copy2(SCRIPTS/'package-emacs.py',self.root/'scripts/package-emacs.py')
        result=self.run_check('package-emacs.py')
        self.assertEqual(result.returncode,0,result.stderr)
        with tarfile.open(frontend/'dist/isled-1.2.3.tar') as archive:
            self.assertEqual(set(archive.getnames()),{
                'isled-1.2.3/isled.el','isled-1.2.3/isled-pkg.el',
                'isled-1.2.3/README.md','isled-1.2.3/user-guide.md',
                'isled-1.2.3/CONTRIBUTING.md','isled-1.2.3/LICENSE',
                'isled-1.2.3/images/hierarchy.gif','isled-1.2.3/images/filtering.gif'})
            self.assertEqual(archive.extractfile('isled-1.2.3/LICENSE').read(),b'MIT fixture\n')
            self.assertIn(b'((emacs "30.1"))',
                          archive.extractfile('isled-1.2.3/isled-pkg.el').read())
        previous = (frontend/'dist/isled-1.2.3.tar').read_bytes()
        self.assertEqual(self.run_check('package-emacs.py').returncode, 0)
        self.assertEqual((frontend/'dist/isled-1.2.3.tar').read_bytes(), previous)


if __name__=='__main__':
    unittest.main()
