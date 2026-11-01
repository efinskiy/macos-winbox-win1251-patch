#!/usr/bin/env python3
"""Run the real patched WinBox decoder path, exiting before application main."""
import json
import argparse
import os
import platform
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
profile = json.loads((ROOT/'profile.json').read_text())
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
parser = argparse.ArgumentParser()
parser.add_argument('--arch', choices=('arm64', 'x86_64'), default=platform.machine())
parser.add_argument('--editor', action='store_true', help='Exercise real TextView refresh')
parser.add_argument('--app', type=Path, required=True, help='Patched WinBox bundle to exercise')
args = parser.parse_args()
arch = args.arch
config = profile['architectures'][arch]
kind = 'editor' if args.editor else 'table'
probe = ROOT/'build'/f'native-probe-{kind}-{arch}.dylib'
subprocess.run(['xcrun', 'clang', '-arch', arch, '-isysroot', sdk, '-std=c11', '-O2',
    '-Wall', '-Wextra', '-Wpedantic', '-Werror', '-Wconversion', '-Wshadow',
    '-mmacosx-version-min=12.0', '-dynamiclib', str(ROOT/('tests/native_editor_probe.c' if args.editor else 'tests/native_probe.c')),
    '-o', str(probe)], check=True)
report = ROOT/'build'/f'native-probe-{kind}-{arch}.json'
if report.exists():
    report.unlink()
env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(probe), WB_PROBE_REPORT=str(report),
    WB_PROBE_MODEL=config['model_data'], WB_PROBE_DESTROY=config['variant_destroy'],
    WINBOX_COMMENT_ENCODING='auto')
if args.editor:
    for key, value in config['editor'].items():
        env['WB_EDITOR_'+key.upper()] = str(value)
executable = str(args.app.resolve()/'Contents/MacOS/WinBox')
command = [executable]
if arch != platform.machine():
    # /usr/bin/arch clears DYLD_*; env sets the probe after that protected hop.
    command = ['/usr/bin/arch', '-'+arch, '/usr/bin/env',
               'DYLD_INSERT_LIBRARIES='+str(probe), executable]
    env.pop('DYLD_INSERT_LIBRARIES', None)
process = subprocess.run(command,
    env=env, capture_output=True, text=True, timeout=30)
print(process.stdout, end='')
print(process.stderr, end='')
if not report.is_file():
    raise RuntimeError(f'WinBox exited {process.returncode} without a probe report')
if not report.stat().st_size:
    raise RuntimeError(f'WinBox exited {process.returncode} before completing the probe')
result = json.loads(report.read_text())
print(json.dumps(result, ensure_ascii=False, indent=2))
if process.returncode != 0 or result.get('failed') != 0:
    raise RuntimeError(f'WinBox native probe failed: exit {process.returncode}')
