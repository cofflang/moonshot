#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# Synthetic tables exercise the actual c0 module through coff1 and smed.
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = 0x100000
X = 64
F = 9000


def put32(b, off, value):
    struct.pack_into('<I', b, off, value)


def put64(b, off, value):
    struct.pack_into('<Q', b, off, value)


def checksum(b, off, length, field):
    b[off + field] = 0
    b[off + field] = -sum(b[off:off + length]) & 255


def sdt(b, off, sig, length, rev):
    b[off:off + 4] = sig
    put32(b, off + 4, length)
    b[off + 8] = rev
    checksum(b, off, length, 9)


def fixture():
    b = bytearray(10000)
    b[:8] = b'RSD PTR '
    b[15] = 2
    put32(b, 20, 36)
    put64(b, 24, BASE + X)
    checksum(b, 0, 20, 8)
    checksum(b, 0, 36, 32)
    put64(b, X + 36, BASE + F)
    sdt(b, X, b'XSDT', 44, 1)
    sdt(b, F, b'FACP', 276, 6)
    return b


def cases():
    result = []

    def add(name, edit=lambda b: None, size=10000, expected=-1, base=BASE, rsdp=0):
        b = fixture()
        edit(b)
        result.append((name, b, size, expected, base, rsdp))

    add('valid', expected=F)
    for rev, length in [(1, 116), (3, 244), (4, 244), (5, 268)]:
        add(f'fadt_rev_{rev}', lambda b, r=rev, n=length: sdt(b, F, b'FACP', n, r), expected=F)
    add('bad_checksum', lambda b: b.__setitem__(F + 10, 1))
    add('truncated_table', size=F + 24)
    add('length_beyond_buffer', size=F + 275)

    def many(b):
        for i in range(1024):
            put64(b, X + 36 + i * 8, BASE + 8400)
        put64(b, X + 36 + 1024 * 8, BASE + F)
        sdt(b, 8400, b'TEST', 36, 1)
        sdt(b, X, b'XSDT', 36 + 1025 * 8, 1)
    add('entry_count_overflow', many)

    def outside(b):
        put64(b, X + 36, BASE + 10000)
        sdt(b, X, b'XSDT', 44, 1)
        b.extend(bytearray(276))
        sdt(b, 10000, b'FACP', 276, 6)
    add('entry_outside_blob', outside)
    add('rsdp_signature', lambda b: b.__setitem__(0, 0))
    add('rsdp_checksum', lambda b: b.__setitem__(9, 1))
    add('rsdp_extended_checksum', lambda b: b.__setitem__(33, 1))
    add('rsdp_truncated', size=35)
    add('rsdp_negative_offset', rsdp=-1)
    for rev in (0, 1):
        def revision(b, r=rev):
            b[15] = r
            checksum(b, 0, 20, 8)
            checksum(b, 0, 36, 32)
        add(f'rsdp_revision_{rev}', revision)
    def extended(b):
        b[15] = 3
        put32(b, 20, 40)
        checksum(b, 0, 20, 8)
        checksum(b, 0, 40, 32)
    add('rsdp_future_extension', extended, expected=F)
    add('rsdp_length_overflow', lambda b: put32(b, 20, 0xffffffff))
    add('sdt_length_overflow', lambda b: put32(b, X + 4, 0xffffffff))
    add('xsdt_signature', lambda b: sdt(b, X, b'RSDT', 44, 1))
    add('xsdt_revision', lambda b: sdt(b, X, b'XSDT', 44, 2))
    add('xsdt_partial_entry', lambda b: sdt(b, X, b'XSDT', 45, 1))
    add('missing_fadt', lambda b: sdt(b, F, b'TEST', 276, 1))
    for rev in (0, 2, 7):
        add(f'fadt_unsupported_{rev}', lambda b, r=rev: sdt(b, F, b'FACP', 276, r))
    add('short_fadt', lambda b: sdt(b, F, b'FACP', 275, 6))
    def duplicate(b):
        put64(b, X + 44, BASE + F)
        sdt(b, X, b'XSDT', 52, 1)
    add('duplicate_fadt', duplicate)
    def walk(b, corrupt=False):
        put64(b, X + 36, BASE + 8400)
        put64(b, X + 44, BASE + F)
        put64(b, X + 52, BASE + 8500)
        sdt(b, 8400, b'TEST', 36, 1)
        sdt(b, 8500, b'SSDT', 36, 2)
        sdt(b, X, b'XSDT', 60, 1)
        if corrupt:
            b[8500 + 10] = 1
    add('walk_unknown_before_and_after_fadt', walk, expected=F)
    add('bad_checksum_after_fadt', lambda b: walk(b, True))
    def pointer(b, value):
        put64(b, X + 36, value)
        sdt(b, X, b'XSDT', 44, 1)
    add('entry_below_base', lambda b: pointer(b, BASE - 1))
    add('entry_high_bit', lambda b: pointer(b, 0xffffffffffffffff))
    add('base_wrap', base=0x7fffffffffffffff)
    return result


def run(source, selected, directory):
    code = source + '\nint main() {\n'
    for index, (name, blob, size, expected, base, rsdp) in enumerate(selected):
        code += f'int b{index} = alloc({len(blob)});\n'
        # Explicit zeroing avoids relying on allocator initial contents.
        code += f'int i{index} = 0; while (i{index} < {len(blob)}) {{ store8(b{index} + i{index}, 0); i{index} += 1; }}\n'
        for off, value in enumerate(blob):
            if value:
                code += f'store8(b{index} + {off}, {value});\n'
        code += f'int r{index} = kraft_parse(b{index}, {size}, {base}, {rsdp});\n'
        condition = f'r{index} != {expected}' if expected >= 0 else f'r{index} >= 0'
        code += f'if ({condition}) {{ print("FAIL {name}\\n"); return 1; }}\n'
        code += f'print("PASS {name}\\n");\n'
    code += 'return 0; }\n'
    src = directory / 'probe.c0'
    asm = directory / 'probe.s'
    exe = directory / 'probe'
    src.write_text(code)
    subprocess.run([str(ROOT.parent / 'c0-coff/coff1'), str(src), str(asm)], check=True, timeout=30)
    subprocess.run([str(ROOT.parent / 'c0-coff/smed'), str(asm), str(exe)], check=True, timeout=30)
    exe.chmod(0o700)
    return subprocess.run([str(exe)], timeout=10, text=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--red-controls', action='store_true')
    args = parser.parse_args()
    source = (ROOT / 'kernel/core/kraft.c0').read_text()
    fixtures = cases()
    with tempfile.TemporaryDirectory(prefix='kraft-') as tmp:
        directory = Path(tmp)
        if args.red_controls:
            controls = {
                'bad_checksum': [('if (kraft_sum(blob, off, len) != 0)', 'if (0)')],
                'truncated_table': [('if (kraft_range(size, off, 36) == 0)', 'if (0)'), ('if (kraft_range(size, off, len) == 0)', 'if (0)')],
                'length_beyond_buffer': [('if (kraft_range(size, off, len) == 0)', 'if (0)')],
                'entry_count_overflow': [('entries > 1024', 'entries < 0')],
                'entry_outside_blob': [('if (off >= size)', 'if (0)'), ('if (kraft_range(size, off, 36) == 0)', 'if (0)'), ('if (kraft_range(size, off, len) == 0)', 'if (0)')],
            }
            for name, replacements in controls.items():
                candidate = source
                for old, new in replacements:
                    assert candidate.count(old) == 1, old
                    candidate = candidate.replace(old, new)
                result = run(candidate, [c for c in fixtures if c[0] == name], directory)
                print(result.stdout, end='')
                assert result.returncode == 1 and f'FAIL {name}' in result.stdout, (name, result.returncode, result.stderr)
                print(f'RED CONTROL {name} detected removed validation')
        else:
            result = run(source, fixtures, directory)
            print(result.stdout, end='')
            assert result.returncode == 0, (result.returncode, result.stderr)


if __name__ == '__main__':
    main()
