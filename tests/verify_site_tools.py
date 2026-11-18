#!/usr/bin/env python3
"""Focused look-alike fixtures for the two private site host tools."""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
COFF = ROOT.parent / 'c0-coff'


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], capture_output=True, text=True, **kwargs)


def compile_tool(source, name, scratch):
    asm = scratch / (name + '.s')
    exe = scratch / name
    for args in [(COFF / 'coff1', source, asm), (COFF / 'smed', asm, exe)]:
        result = run(args)
        assert result.returncode == 0, result.stdout + result.stderr
    exe.chmod(0o700)
    return exe


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def png(width, height):
    raw = (b'\0' + bytes((235, 45, 90)) * width) * height
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def invalid_jpeg_run():
    def segment(marker, data):
        return bytes((255, marker)) + struct.pack('>H', len(data) + 2) + data
    counts = bytes((1,)) + bytes(15)
    return (b'\xff\xd8' + segment(219, bytes((0,)) + bytes((1,)) * 64)
            + segment(192, bytes((8, 0, 8, 0, 8, 1, 1, 17, 0)))
            + segment(196, bytes((0,)) + counts + bytes((0,))
                      + bytes((16,)) + counts + bytes((16,)))
            + segment(218, bytes((1, 1, 0, 0, 63, 0))) + b'\x3f\xff\xd9')


def refusal(exe, args, message):
    result = run((exe, *args))
    assert result.returncode != 0, 'accepted ' + message
    assert message in result.stdout, result.stdout + result.stderr
    print('PASS refusal ' + message)


def checks(copy, images, scratch, case=None):
    out = scratch / 'output.spr'
    if case is None:
        for source in sorted((ROOT / 'tests/fixtures/site-images').iterdir()):
            result = run((images, source, out))
            assert result.returncode == 0, source.name + result.stdout + result.stderr
            data = out.read_bytes()
            w, h, frames = struct.unpack('<qqq', data[:24])
            assert 0 < w <= 160 and 0 < h <= 120 and frames == 1
            assert len(data) == 24 + w * h * 4
            colours = [tuple(data[i:i+4]) for i in range(24, len(data), 4)]
            assert all(abs(b-90) <= 4 and abs(g-45) <= 4 and abs(r-235) <= 4 and a == 255
                       for b, g, r, a in colours), (source.name, colours[:4])
            print('PASS pixel oracle ' + source.name)
    if case in (None, 'inflate'):
        import random
        noisy = scratch / 'blocks.png'
        rowbytes = random.Random(42).randbytes(2600 * 2600 * 4).translate(bytes(i & 127 for i in range(256)))
        raw = b''.join(b'\0' + rowbytes[i:i+10400] for i in range(0, len(rowbytes), 10400))
        noisy.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2600, 2600, 8, 6, 0, 0, 0))
                          + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
        result = run((images, noisy, out))
        assert result.returncode == 0, 'inflate budget ' + result.stdout + result.stderr
        assert len(out.read_bytes()) <= 24 + 160 * 120 * 4
        print('PASS 2600x2600 zlib-6 PNG within conversion budget')
    if case in (None, 'oversized'):
        large = scratch / 'oversized.png'
        large.write_bytes(png(8193, 1))
        refusal(images, (large, out), 'oversized image dimensions')
    if case in (None, 'malformed'):
        malformed = scratch / 'malformed.png'
        data = bytearray(png(32, 24))
        data[-1] ^= 1
        malformed.write_bytes(data)
        refusal(images, (malformed, out), 'PNG CRC mismatch')
    if case is None:
        malformed_jpeg = scratch / 'malformed.jpg'
        malformed_jpeg.write_bytes(invalid_jpeg_run())
        refusal(images, (malformed_jpeg, out), 'invalid sequential JPEG zero run')
    payload = scratch / 'file.html'
    payload.write_text('<p>A look-alike fixture</p>\n')
    disk = scratch / 'disk.img'
    if case in (None, 'nodes'):
        pairs = []
        for i in range(39):
            pairs += ['file' + str(i), payload]
        refusal(copy, (disk, *pairs), 'site node budget')
        if case is None:
            result = run((copy, disk, *pairs[:-2]))
            assert result.returncode == 0, result.stdout + result.stderr
            entries = disk.read_bytes()[512:8704]
            count = sum(struct.unpack_from('<q', entries, i * 64)[0] != 0 for i in range(128))
            assert count == 40 and count + 73 <= 128
            print('PASS full 40-node disk leaves room for 73 seeded test nodes')
    if case in (None, 'bytes'):
        large = scratch / 'large.html'
        large.write_bytes(b'x' * 1048577)
        refusal(copy, (disk, 'large.html', large), 'site byte budget')
    if case is None:
        result = run((copy, disk, 'index.html', payload, 'nested/page.html', payload))
        assert result.returncode == 0, result.stdout + result.stderr
        data = disk.read_bytes()
        assert data[:8] == b'JAKELBK\0' and len(data) == 10485760
        assert struct.unpack('<qqqqq', data[8:48]) == (1, 128, 32, 17, 2)
        entries = [struct.unpack('<qqqq32s', data[512+i*64:576+i*64]) for i in range(128)]
        assert [(e[0], e[1], e[4].split(b'\0')[0]) for e in entries[:5]] == [
            (2, 0, b'/'), (2, 0, b'site'), (1, 1, b'index.html'), (2, 1, b'nested'), (1, 3, b'page.html')]
        assert data[8704:8704+len(payload.read_bytes())] == payload.read_bytes()
        assert data[9216:9216+len(payload.read_bytes())] == payload.read_bytes()
        result = run((copy, disk))
        assert result.returncode == 0, result.stdout + result.stderr
        assert b'site' not in disk.read_bytes()[512:8704]
        print('PASS disk structure, file bytes and absent /site')
        result = run((sys.executable, ROOT / 'tests/verify_site_build.py', '--case', 'skips'))
        assert result.returncode == 0, result.stdout + result.stderr
        print(result.stdout, end='')



def main():
    with tempfile.TemporaryDirectory(prefix='bl012c-tools-', dir=os.environ.get('TMPDIR', '/tmp')) as temporary:
        scratch = Path(temporary)
        copy_source = ROOT / 'tools/site_copy.c0'
        image_source = ROOT / 'tools/site_images.c0'
        copy = compile_tool(copy_source, 'copy', scratch)
        images = compile_tool(image_source, 'images', scratch)
        if sys.argv[1:] == ['--mutants']:
            mutations = {
                'inflate': (image_source, 'int i = 0;\n    for (i=0; i<32768;', 'table = bounded_alloc(32768*8); int i = 0;\n    for (i=0; i<32768;'),
                'oversized': (image_source, 'w > 8192', 'w > 16384'),
                'malformed': (image_source, 'crc(input+start,n+4) != check', '0'),
                'nodes': (copy_source, 'nodes >= 40', 'nodes >= 64'),
                'bytes': (copy_source, '1048576', '2097152'),
            }
            for name, (source, old, new) in mutations.items():
                text = source.read_text()
                assert old in text
                text = text.replace(old, new)
                if name == 'bytes':
                    text = text.replace('1048577', '2097153')
                mutant = scratch / (name + '.c0')
                mutant.write_text(text)
                exe = compile_tool(mutant, name, scratch)
                try:
                    checks(exe if source == copy_source else copy,
                           exe if source == image_source else images, scratch, name)
                except AssertionError as error:
                    assert str(error).startswith(('accepted ', 'inflate budget ')), str(error)
                    print('RED ' + name + ' ' + str(error))
                else:
                    raise AssertionError('mutation survived ' + name)
        else:
            checks(copy, images, scratch)


if __name__ == '__main__':
    main()
