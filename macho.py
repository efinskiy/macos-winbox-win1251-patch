"""Bounded Mach-O access for the pinned WinBox patch; no third-party packages."""
import struct


class MachO:
    def __init__(self, data):
        self.data = bytearray(data)
        if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
            raise ValueError('expected little-endian 64-bit Mach-O')
        self.ncmds, self.sizeofcmds = struct.unpack_from('<II', data, 16)
        if self.ncmds > 4096 or 32 + self.sizeofcmds > len(data):
            raise ValueError('invalid load-command bounds')
        self.commands, self.segments, self.sections = [], [], []
        pos = 32
        for _ in range(self.ncmds):
            cmd, size = struct.unpack_from('<II', data, pos)
            if size < 8 or size % 8 or pos + size > 32 + self.sizeofcmds:
                raise ValueError('invalid load command')
            self.commands.append((cmd, pos, size))
            if cmd == 0x19:
                if size < 72:
                    raise ValueError('truncated segment')
                fields = struct.unpack_from('<II16sQQQQiiII', data, pos)
                name = fields[2].rstrip(b'\0').decode('ascii')
                va, vsize, off, fsize, nsects = fields[3:7] + (fields[9],)
                if nsects > 256 or 72 + 80 * nsects > size or off + fsize > len(data):
                    raise ValueError('invalid segment bounds')
                self.segments.append((name, va, vsize, off, fsize))
                for k in range(nsects):
                    s = struct.unpack_from('<16s16sQQIIIIIIII', data, pos + 72 + 80*k)
                    self.sections.append({'name': s[0].rstrip(b'\0').decode('ascii'),
                        'segment': name, 'addr': s[2], 'size': s[3], 'offset': s[4],
                        'relocations': s[6], 'nreloc': s[7]})
            pos += size
        if pos != 32 + self.sizeofcmds:
            raise ValueError('load commands do not consume declared size')

    def file_offset(self, address, size=1):
        for _, va, _, off, fsize in self.segments:
            if va <= address and address + size <= va + fsize:
                return off + address - va
        raise ValueError(f'address is not file-backed: {address:#x}')

    def add_dylib(self, name):
        encoded = name.encode() + b'\0'
        size = (24 + len(encoded) + 7) & ~7
        pos = 32 + self.sizeofcmds
        first = min(s['offset'] for s in self.sections if s['offset'] > 0)
        if pos + size > first or any(self.data[pos:pos+size]):
            raise ValueError('no verified zero header padding for LC_LOAD_DYLIB')
        command = struct.pack('<6I', 0xc, size, 24, 0, 0x10000, 0x10000)
        command += encoded
        self.data[pos:pos+size] = command.ljust(size, b'\0')
        struct.pack_into('<II', self.data, 16, self.ncmds + 1, self.sizeofcmds + size)


def fat_slices(data):
    if len(data) < 8 or data[:4] != bytes.fromhex('cafebabe'):
        raise ValueError('expected FAT_MAGIC universal binary')
    count = struct.unpack_from('>I', data, 4)[0]
    if not 1 <= count <= 8 or 8 + 20 * count > len(data):
        raise ValueError('invalid universal header')
    result = []
    for i in range(count):
        cpu, sub, off, size, align = struct.unpack_from('>5I', data, 8 + 20*i)
        if align > 30 or off % (1 << align) or off < 8 + 20*count or off + size > len(data):
            raise ValueError('invalid universal slice')
        if any(off < other[1] + other[2] and other[1] < off + size for other in result):
            raise ValueError('overlapping slices')
        result.append((cpu, off, size, sub))
    return result
