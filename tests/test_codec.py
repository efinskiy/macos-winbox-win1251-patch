#!/usr/bin/env python3
import ctypes
import random
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
LIB = ROOT/'build'/'test-codec.dylib'
LIB.parent.mkdir(exist_ok=True)
subprocess.run(['xcrun', 'clang', '-isysroot', sdk, '-std=c11', '-O2', '-Wall',
    '-Wextra', '-Wpedantic', '-Werror', '-dynamiclib', str(ROOT/'src/codec.c'),
    '-o', str(LIB)], check=True)
codec = ctypes.CDLL(str(LIB))
codec.wb_decode_comment.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                                   ctypes.c_size_t, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
codec.wb_decode_comment.restype = ctypes.c_int


def decode(data, mode=0, capacity=None):
    out = ctypes.create_string_buffer(capacity if capacity is not None else 3*len(data)+1)
    written = ctypes.c_size_t(777)
    status = codec.wb_decode_comment(data, len(data), out, len(out), mode, ctypes.byref(written))
    return status, out.raw[:written.value], written.value, out.raw[0]


class CodecTests(unittest.TestCase):
    def test_all_cp1251_bytes_against_python_codec(self):
        for byte in range(256):
            data = bytes([byte])
            if byte == 0x98:
                self.assertEqual(decode(data, 2), (3, b'', 0, 0))
            else:
                self.assertEqual(decode(data, 2)[1], data.decode('cp1251').encode('utf-8'))

    def test_auto_against_independent_decoders(self):
        rng = random.Random(1251)
        vectors = [b'', 'Привет Ёё 😀 �'.encode(), bytes.fromhex('d0a1'),
                   bytes.fromhex('c080'), bytes.fromhex('eda080'), bytes.fromhex('f4908080')]
        vectors += [rng.randbytes(rng.randrange(1, 64)) for _ in range(20000)]
        for data in vectors:
            try:
                expected = data.decode('utf-8').encode('utf-8')
                success = 0
            except UnicodeDecodeError:
                try:
                    expected = data.decode('cp1251').encode('utf-8')
                    success = 1
                except UnicodeDecodeError:
                    self.assertEqual(decode(data), (3, b'', 0, 0))
                    continue
            status, out, length, _ = decode(data)
            self.assertEqual((status, out, length), (success, expected, len(expected)))

    def test_rejects_without_stale_output(self):
        self.assertEqual(decode(b'\xff', 1), (2, b'', 0, 0))
        self.assertEqual(decode(b'abc', capacity=3), (5, b'', 0, 0))
        self.assertEqual(decode(b'abc', mode=77), (2, b'', 0, 0))
        self.assertEqual(decode(b'x' * (1048576+1), capacity=1), (4, b'', 0, 0))

    def test_modes_resolve_ambiguity(self):
        self.assertEqual(decode(bytes.fromhex('d0a1'))[1].decode(), 'С')
        self.assertEqual(decode(bytes.fromhex('d0a1'), 2)[1].decode(), 'РЎ')


if __name__ == '__main__':
    unittest.main()
