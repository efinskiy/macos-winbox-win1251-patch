#!/usr/bin/env python3
import ctypes
import os
import platform
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

    widget_callback = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)

    @widget_callback
    def setter(widget, text):
        assert widget == 456
        received.append(text)

    lib.wb_comment_widget_v1.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        widget_callback, ctypes.c_void_p]
    lib.wb_comment_widget_v1.restype = None
    for label, comment in ((b'Comment', True), (b'Name', False), (b'comment', False)):
        for long_storage in (False, True):
            storage = bytearray(24)
            label_buffer = ctypes.create_string_buffer(label)
            pointer = ctypes.addressof(label_buffer).to_bytes(8, 'little')
            if platform.machine() == 'arm64':
                if long_storage:
                    storage[:8] = pointer
                    storage[8:16] = len(label).to_bytes(8, 'little')
                    storage[23] = 128
                else:
                    storage[:len(label)] = label
                    storage[23] = len(label)
            else:
                if long_storage:
                    storage[0] = 1
                    storage[8:16] = len(label).to_bytes(8, 'little')
                    storage[16:24] = pointer
                else:
                    storage[0] = 2 * len(label)
                    storage[1:len(label)+1] = label
            label_storage = ctypes.create_string_buffer(bytes(storage))
            raw = ctypes.create_string_buffer('Привет'.encode('cp1251'))
            before = raw.raw
            received.clear()
            lib.wb_comment_widget_v1(456, raw, setter, label_storage)
            expected = (b'' if mode in ('utf-8', 'invalid') else 'Привет'.encode()) if comment else raw.value
            assert received == [expected], (mode, label, long_storage, received)
            assert raw.raw == before


if __name__ == '__main__':
    if len(sys.argv) == 2:
        child(sys.argv[1])
    else:
        for mode in ('auto', 'utf-8', 'windows-1251', 'config-file', 'invalid'):
            subprocess.run([sys.executable, __file__, mode], check=True)
        print('Bridge: all encoding modes, config file, editor field isolation, source preservation, rejection and counters passed')
