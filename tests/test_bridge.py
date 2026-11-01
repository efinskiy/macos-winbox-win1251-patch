#!/usr/bin/env python3
import ctypes
import os
import subprocess
import sys
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
fixture = ROOT/'build/bridge-fixture/Contents'
library = fixture/'Frameworks/libWinBoxCommentEncoding.dylib'
library.parent.mkdir(parents=True, exist_ok=True)
(fixture/'Resources').mkdir(exist_ok=True)
if len(sys.argv) == 1:
    shutil.copyfile(ROOT/'build/libWinBoxCommentEncoding.dylib', library)
(fixture/'Resources/comment-encoding.conf').write_text('encoding=auto\n')


def child(mode):
    if mode == 'config-file':
        os.environ.pop('WINBOX_COMMENT_ENCODING', None)
    else:
        os.environ['WINBOX_COMMENT_ENCODING'] = mode
    lib = ctypes.CDLL(str(library))
    callback_type = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p)
    received = []

    @callback_type
    def original(result, text):
        received.append(text)
        return result

    lib.wb_comment_variant_v1.argtypes = [ctypes.c_void_p, ctypes.c_char_p, callback_type]
    lib.wb_comment_variant_v1.restype = ctypes.c_void_p
    lib.wb_comment_counter_v1.argtypes = [ctypes.c_uint]
    lib.wb_comment_counter_v1.restype = ctypes.c_ulong
    actual = lib.wb_comment_variant_v1(123, bytes.fromhex('d0a1'), original)
    assert actual == 123
    if mode == 'windows-1251':
        assert received == ['РЎ'.encode()]
        assert lib.wb_comment_counter_v1(1) == 1
    elif mode == 'invalid':
        assert received == [b'']
        assert lib.wb_comment_counter_v1(2) == 1
    else:
        assert received == ['С'.encode()]
        assert lib.wb_comment_counter_v1(0) == 1
    received.clear()
    lib.wb_comment_variant_v1(123, 'Привет'.encode('cp1251'), original)
    assert received == ([b''] if mode in ('utf-8', 'invalid') else ['Привет'.encode()])


if __name__ == '__main__':
    if len(sys.argv) == 2:
        child(sys.argv[1])
    else:
        for mode in ('auto', 'utf-8', 'windows-1251', 'config-file', 'invalid'):
            subprocess.run([sys.executable, __file__, mode], check=True)
        print('Bridge: all encoding modes, config file, rejection and counters passed')
