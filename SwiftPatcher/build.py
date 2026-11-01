#!/usr/bin/env python3
"""Build a standalone universal Swift app with all patch resources embedded."""
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PATCH = ROOT.parent
sys.path.insert(0, str(PATCH))
from trampoline import build_thunk

APP = ROOT/'dist/WinBox Comment Patcher.app'
BUILD = ROOT/'build'


def main():
    BUILD.mkdir(exist_ok=True)
    version = (PATCH/'VERSION').read_text().strip()
    if re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version) is None:
        raise ValueError('VERSION must contain MAJOR.MINOR.PATCH')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    sources = sorted(str(p) for p in (ROOT/'Sources').glob('*.swift'))
    executables = []
    for arch in ('arm64', 'x86_64'):
        binary = BUILD/f'WinBoxCommentPatcher-{arch}'
        subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-target', f'{arch}-apple-macosx12.0',
            '-module-cache-path', str(BUILD/'ModuleCache'),
            '-swift-version', '5', '-warnings-as-errors', '-O', '-parse-as-library',
            '-framework', 'AppKit', '-framework', 'CryptoKit', *sources, '-o', str(binary)], check=True)
        executables.append(str(binary))
    with tempfile.TemporaryDirectory(prefix="winbox-patcher-build-", dir="/private/tmp") as temporary:
        staged = Path(temporary)/APP.name
        macos, resources = staged/'Contents/MacOS', staged/'Contents/Resources'
        macos.mkdir(parents=True)
        resources.mkdir(parents=True)
        subprocess.run(['xcrun', 'lipo', '-create', *executables, '-output', str(macos/'WinBoxCommentPatcher')], check=True)
        profile = json.loads((PATCH/'profile.json').read_text())
        shutil.copyfile(PATCH/'profile.json', resources/'profile.json')
        shutil.copyfile(PATCH/'build/libWinBoxCommentEncoding.dylib', resources/'libWinBoxCommentEncoding.dylib')
        for arch, config in profile['architectures'].items():
            (resources/f'{arch}-thunk.bin').write_bytes(build_thunk(arch, config, BUILD))
            (resources/f'{arch}-legacy-thunk.bin').write_bytes(build_thunk(arch, config, BUILD, include_editor=False))
        plist = {'CFBundleName': 'WinBox Comment Patcher', 'CFBundleDisplayName': 'WinBox Comment Patcher',
            'CFBundleIdentifier': 'local.winbox.comment-patcher', 'CFBundleVersion': version,
            'CFBundleShortVersionString': version, 'CFBundleExecutable': 'WinBoxCommentPatcher',
            'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '12.0',
            'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication'}
        (staged/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
        for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
            subprocess.run(['xattr', '-dr', attribute, str(staged)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(resources/'libWinBoxCommentEncoding.dylib')], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(staged)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        archive = APP.parent/f'WinBox-Comment-Patcher-{version}.zip'
        subprocess.run(['ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr',
            str(staged), str(archive)], check=True)
        if APP.exists():
            shutil.rmtree(APP)
        shutil.copytree(staged, APP)
        for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
            subprocess.run(['xattr', '-dr', attribute, str(APP)], check=True)
    print(APP)


if __name__ == '__main__':
    main()
