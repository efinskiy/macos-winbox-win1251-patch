"""Assemble PC-relative entry thunks without introducing dyld relocations."""
import struct
import subprocess
from pathlib import Path
from macho import MachO


def build_thunk(arch, config, directory, include_editor=True):
    cave, original, dlsym = (int(config[k], 0) for k in ('cave', 'original_helper', 'dlsym'))
    if arch == 'arm64':
        # All external references remain relative to the same image, including under ASLR.
        source = f'''.text
.p2align 2
.globl _wb_thunk
_wb_thunk:
stp x29, x30, [sp, #-48]!
mov x29, sp
stp x19, x20, [sp, #16]
mov x19, x0
mov x20, x1
mov x0, #-2
adr x1, Lsymbol
.long 0x94000000 | ((({dlsym} - ({cave} + (. - _wb_thunk))) / 4) & 0x3ffffff)
mov x16, x0
mov x0, x19
mov x1, x20
.set page_delta, (({original} >> 12) - (({cave} + (. - _wb_thunk)) >> 12))
.long 0x90000002 | ((page_delta & 3) << 29) | (((page_delta >> 2) & 0x7ffff) << 5)
add x2, x2, #{original & 0xfff}
cbz x16, Lmissing
blr x16
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp], #48
ret
Lmissing:
mov x16, x2
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp], #48
br x16
Lsymbol:
.asciz "wb_comment_variant_v1"
'''
    elif arch == 'x86_64':
        continuation = int(config['continuation'], 0)
        source = f'''.text
.globl _wb_thunk
_wb_thunk:
movq 0x1b8(%r14), %rcx
movq (%rcx,%rax,8), %rsi
testb $1, 0x30(%rsi)
jz Lshort
movq 0x40(%rsi), %rsi
jmp Lgot
Lshort:
leaq 0x31(%rsi), %rsi
Lgot:
subq $16, %rsp
movq %rsi, (%rsp)
movq $-2, %rdi
leaq Lsymbol(%rip), %rsi
.byte 0xe8
.long {dlsym} - ({cave} + (. - _wb_thunk) + 4)
movq %rax, %r11
movq (%rsp), %rsi
addq $16, %rsp
movq %rbx, %rdi
.byte 0x48, 0x8d, 0x15
.long {original} - ({cave} + (. - _wb_thunk) + 4)
testq %r11, %r11
jz Lmissing
callq *%r11
.byte 0xe9
.long {continuation} - ({cave} + (. - _wb_thunk) + 4)
Lmissing:
callq *%rdx
.byte 0xe9
.long {continuation} - ({cave} + (. - _wb_thunk) + 4)
Lsymbol:
.asciz "wb_comment_variant_v1"
'''
    else:
        raise ValueError('unsupported architecture')
    asm, obj = Path(directory)/f'{arch}-thunk.s', Path(directory)/f'{arch}-thunk.o'
    asm.write_text(source)
    subprocess.run(['xcrun', 'clang', '-arch', arch, '-c', str(asm), '-o', str(obj)], check=True)
    m = MachO(obj.read_bytes())
    section, = [s for s in m.sections if s['name'] == '__text']
    if section['nreloc'] != 0:
        raise ValueError('unexpected unresolved thunk relocation')
    table = bytes(m.data[section['offset']:section['offset']+section['size']])
    if not include_editor or 'editor' not in config:
        return table
    editor = config['editor']
    offset = editor['thunk_offset']
    if len(table) > offset:
        raise ValueError('table thunk overlaps editor thunk')
    return table.ljust(offset, b'\0') + build_editor_thunk(arch, config, directory)


def build_editor_thunk(arch, config, directory):
    editor = config['editor']
    cave = int(config['cave'], 0) + editor['thunk_offset']
    original, dlsym = int(editor['original_helper'], 0), int(config['dlsym'], 0)
    label = editor['widget_label_offset']
    if arch == 'arm64':
        source = f'''.text
.p2align 2
.globl _wb_editor
_wb_editor:
stp x29, x30, [sp, #-48]!
mov x29, sp
stp x19, x20, [sp, #16]
mov x19, x0
mov x20, x1
mov x0, #-2
adr x1, Lsymbol
.long 0x94000000 | ((({dlsym} - ({cave} + (. - _wb_editor))) / 4) & 0x3ffffff)
mov x16, x0
mov x0, x19
mov x1, x20
.set page_delta, (({original} >> 12) - (({cave} + (. - _wb_editor)) >> 12))
.long 0x90000002 | ((page_delta & 3) << 29) | (((page_delta >> 2) & 0x7ffff) << 5)
add x2, x2, #{original & 0xfff}
add x3, x19, #{label}
cbz x16, Lmissing
blr x16
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp], #48
ret
Lmissing:
mov x16, x2
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp], #48
br x16
Lsymbol:
.asciz "wb_comment_widget_v1"
'''
    elif arch == 'x86_64':
        source = f'''.text
.globl _wb_editor
_wb_editor:
pushq %rbp
movq %rsp, %rbp
pushq %r12
pushq %r13
movq %rdi, %r12
movq %rsi, %r13
movq $-2, %rdi
leaq Lsymbol(%rip), %rsi
.byte 0xe8
.long {dlsym} - ({cave} + (. - _wb_editor) + 4)
movq %rax, %r11
movq %r12, %rdi
movq %r13, %rsi
.byte 0x48, 0x8d, 0x15
.long {original} - ({cave} + (. - _wb_editor) + 4)
leaq {label}(%r12), %rcx
testq %r11, %r11
jz Lmissing
callq *%r11
jmp Ldone
Lmissing:
callq *%rdx
Ldone:
popq %r13
popq %r12
popq %rbp
retq
Lsymbol:
.asciz "wb_comment_widget_v1"
'''
    else:
        raise ValueError('unsupported architecture')
    asm, obj = Path(directory)/f'{arch}-editor.s', Path(directory)/f'{arch}-editor.o'
    asm.write_text(source)
    subprocess.run(['xcrun', 'clang', '-arch', arch, '-c', str(asm), '-o', str(obj)], check=True)
    m = MachO(obj.read_bytes())
    section, = [s for s in m.sections if s['name'] == '__text']
    if section['nreloc']:
        raise ValueError('unresolved editor thunk relocation')
    return bytes(m.data[section['offset']:section['offset']+section['size']])


def branch_patch(arch, site, cave, length):
    if arch == 'arm64':
        delta = cave - site
        if length != 4 or delta % 4 or not -(1 << 27) <= delta < (1 << 27):
            raise ValueError('arm64 branch out of range')
        return struct.pack('<I', 0x14000000 | ((delta // 4) & 0x3ffffff))
    delta = cave - (site + 5)
    if length < 5 or not -(1 << 31) <= delta < (1 << 31):
        raise ValueError('x86 branch out of range')
    return b'\xe9' + struct.pack('<i', delta) + b'\x90' * (length - 5)
