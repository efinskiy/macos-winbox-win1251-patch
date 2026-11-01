#!/usr/bin/env python3
"""Exercise the shipped Swift engine against actual WinBox bundle fixtures."""
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BINARY = ROOT/'dist/WinBox Comment Patcher.app/Contents/MacOS/WinBoxCommentPatcher'
SOURCE = Path('/Applications/WinBox.app')
PROFILE = json.loads((ROOT.parent/'profile.json').read_text())


def digest(app):
    return hashlib.sha256((app/'Contents/MacOS/WinBox').read_bytes()).hexdigest()


def main():
    global SOURCE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=SOURCE)
    SOURCE = parser.parse_args().source.resolve()
    initial_hash = digest(SOURCE)
    assert initial_hash in [PROFILE['sha256'], *PROFILE['legacy_sha256']]
    (ROOT/'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='in-place-', dir=ROOT/'build') as temporary:
        folder = Path(temporary)
        target, rollback = folder/'Target.app', folder/'Rollback.app'
        for app in (target, rollback):
            shutil.copytree(SOURCE, app, symlinks=True)
        result = subprocess.run([str(BINARY), '--self-test', str(target)],
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        assert target.is_dir() and digest(target) != initial_hash
        patched_hash = digest(target)
        rejected = subprocess.run([str(BINARY), '--self-test', str(target)],
                                  capture_output=True, text=True, timeout=15)
        assert rejected.returncode != 0 and digest(target) == patched_hash
        result = subprocess.run([str(BINARY), '--self-test-rollback', str(rollback)],
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'Rollback verified:' in result.stdout
        assert digest(rollback) == initial_hash
        journals = [json.loads(p.read_text()) for p in (folder/'.winbox-comment-backups').glob('*.json')]
        assert {j['state'] for j in journals} == {'committed', 'rolled_back'}
        for journal in journals:
            with zipfile.ZipFile(journal['backup']) as archive:
                member = Path(journal['application']).name+'/Contents/MacOS/WinBox'
                assert hashlib.sha256(archive.read(member)).hexdigest() == initial_hash
        assert not list(folder.glob('.winbox-patch-*'))
        assert digest(SOURCE) == initial_hash
        report = {'same_path_update': True, 'backup_original_hash': True,
                  'post_commit_failure_rollback': True, 'repeat_patch_rejected': True,
                  'temporary_installation_cleaned': True, 'installed_source_unchanged': True}
        (ROOT/'build/in-place-verification.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
