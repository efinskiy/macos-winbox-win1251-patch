#!/usr/bin/env python3
"""Verify the released ZIP itself, then generate its metadata and checksum."""
import hashlib
import json
import os
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path
from version import ROOT, version


def main():
    value = version()
    dist = ROOT/'SwiftPatcher/dist'
    archive = dist/f'WinBox-Comment-Patcher-{value}.zip'
    with zipfile.ZipFile(archive) as zipped:
        if zipped.testzip() is not None:
            raise ValueError('Release ZIP failed CRC verification')
        names = zipped.namelist()
        if any(not n.startswith('WinBox Comment Patcher.app/') or '..' in Path(n).parts for n in names):
            raise ValueError('Release ZIP contains an unexpected path')
        plist = plistlib.loads(zipped.read('WinBox Comment Patcher.app/Contents/Info.plist'))
        if plist['CFBundleShortVersionString'] != value or plist['LSMinimumSystemVersion'] != '12.0':
            raise ValueError('Packaged application version or minimum macOS differs')
    with tempfile.TemporaryDirectory(prefix='verify-winbox-patcher-', dir='/private/tmp') as temporary:
        subprocess.run(['ditto', '-x', '-k', str(archive), temporary], check=True)
        app = Path(temporary)/'WinBox Comment Patcher.app'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        resources = app/'Contents/Resources'
        profile = json.loads((resources/'profile.json').read_text())
        if profile != json.loads((ROOT/'profile.json').read_text()):
            raise ValueError('Packaged target profile differs from repository')
        for binary in (app/'Contents/MacOS/WinBoxCommentPatcher', resources/'libWinBoxCommentEncoding.dylib'):
            archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).split()
            if set(archs) != {'arm64', 'x86_64'}:
                raise ValueError(f'{binary.name} is not universal arm64 + x86_64')
        for architecture, configuration in profile['architectures'].items():
            size = (resources/f'{architecture}-thunk.bin').stat().st_size
            if not 0 < size <= configuration['cave_capacity']:
                raise ValueError('Invalid packaged trampoline size')
            legacy_size = (resources/f'{architecture}-legacy-thunk.bin').stat().st_size
            if not 0 < legacy_size <= configuration['editor']['thunk_offset'] < size:
                raise ValueError('Missing editor trampoline or invalid upgrade payload')
    info = {'version': value, 'architectures': ['arm64', 'x86_64'], 'minimum_macos': '12.0',
        'supported_winbox': profile['version'], 'supported_winbox_sha256': profile['sha256'],
        'supported_upgrade_sha256': profile['legacy_sha256'],
        'comment_display': ['table', 'object-editor'],
        'signature': 'ad-hoc', 'notarized': False, 'commit': os.environ.get('GITHUB_SHA')}
    metadata = dist/'build-info.json'
    metadata.write_text(json.dumps(info, indent=2)+'\n')
    checksums = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
                        for p in (archive, metadata))
    (dist/'SHA256SUMS').write_text(checksums)
    print('Verified ZIP, code signatures, both architectures and embedded profile')
    print(checksums, end='')


if __name__ == '__main__':
    main()
