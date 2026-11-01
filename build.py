#!/usr/bin/env python3
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT/'build'
FLAGS = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
         '-Wconversion', '-Wshadow', '-fvisibility=hidden', '-mmacosx-version-min=12.0']


def main():
    BUILD.mkdir(exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    for arch in ('arm64', 'x86_64'):
        subprocess.run(['xcrun', 'clang', '-arch', arch, '-isysroot', sdk, *FLAGS, '-dynamiclib',
            str(ROOT/'src/codec.c'), str(ROOT/'src/bridge.c'),
            '-Wl,-install_name,@rpath/libWinBoxCommentEncoding.dylib',
            '-o', str(BUILD/f'decoder-{arch}.dylib')], check=True)
    subprocess.run(['xcrun', 'lipo', '-create', str(BUILD/'decoder-arm64.dylib'),
        str(BUILD/'decoder-x86_64.dylib'), '-output',
        str(BUILD/'libWinBoxCommentEncoding.dylib')], check=True)
    print('Built universal decoder: arm64 + x86_64; strict warnings passed')


if __name__ == '__main__':
    main()
