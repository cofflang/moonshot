import ast
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]


def privacy():
    if not (ROOT / 'sync_release.py').exists():
        print('SKIP release refusal words, sync_release.py is not in this tree')
        return
    module = ast.parse((ROOT / 'sync_release.py').read_text())
    words = next(ast.literal_eval(node.iter) for node in ast.walk(module)
                 if isinstance(node, ast.comprehension) and isinstance(node.target, ast.Name)
                 and node.target.id == 'word' and isinstance(node.iter, ast.Tuple)
                 and all(isinstance(x, ast.Constant) and isinstance(x.value, bytes) for x in node.iter.elts))
    strip = next(ast.literal_eval(node.value.args[0]) for node in module.body
                 if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'STRIP_WORDS' for t in node.targets))
    files = [ROOT / 'build.sh', *ROOT.glob('run_*.sh')]
    for directory in ('kernel', 'programs', 'tests', 'tools'):
        files.extend(p for p in (ROOT / directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    for path in files:
        data = path.read_bytes()
        assert not any(word in data for word in words + (b'tavro' + b'.se',)), str(path)
    touched = ['build.sh', 'tools/site_copy.c0', 'tools/site_images.c0']
    touched += [str(p.relative_to(ROOT)) for p in (ROOT / 'tests').glob('*site*') if p.is_file()]
    for name in touched:
        assert not re.search(strip, (ROOT / name).read_text(errors='replace')), name
    print('PASS release refusal words across shipped files and strip words across site deliverables')


def ddc(work):
    tree = work / 'moonshot'
    tree.mkdir()
    for name in ('build.sh', 'tools', 'kernel', 'programs', 'tests'):
        src = ROOT / name
        if src.is_dir():
            shutil.copytree(src, tree / name, ignore=shutil.ignore_patterns('__pycache__'))
        else:
            shutil.copy2(src, tree / name)
    for name in ('c0-coff', 'gnista', 'utsikt'):
        (work / name).symlink_to(ROOT.parent / name, target_is_directory=True)
    scratch = work / 'ddc'
    scratch.mkdir()
    result = subprocess.run([str(ROOT.parent / 'c0-coff/ddc_entries.sh'), 'moonshot', str(tree), str(scratch)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    for name in ('site_copy', 'site_images'):
        assert 'tools/' + name + '.c0' in result.stdout
    print('PASS DDC list in disposable copy includes both site tools')


def dots(work):
    guard = (ROOT / 'build.sh').read_text().split('# BEGIN SITE GUARD\n')[1].split('# END SITE GUARD')[0]
    home = Path(HOME_FIXTURE)
    config = home / '.config/moonshot'
    config.mkdir(parents=True)
    source = work / 'site'
    source.mkdir()
    listing = config / 'site-files'
    rootfile = config / 'site-root'
    env = dict(os.environ, HOME=str(home))
    for name in ('.hidden/file', 'dir/.hidden', '.file'):
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.is_dir():
            target.write_text('fixture')
        listing.write_text(name + '\n')
        rootfile.write_text(str(source) + '\n')
        result = subprocess.run(['bash', '-eu', '-c', guard + '\nsite_guard "" "$HOME/.config/moonshot/site-files" "$HOME/.config/moonshot/site-root"'], env=env, capture_output=True, text=True)
        assert result.returncode != 0 and 'refuses' in result.stderr, name + result.stderr
    hidden = work / '.root'
    hidden.mkdir()
    (hidden / 'file').write_text('fixture')
    rootfile.write_text(str(hidden) + '\n')
    listing.write_text('file\n')
    result = subprocess.run(['bash', '-eu', '-c', guard + '\nsite_guard "" "$HOME/.config/moonshot/site-files" "$HOME/.config/moonshot/site-root"'], env=env, capture_output=True, text=True)
    assert result.returncode != 0 and 'refuses' in result.stderr, result
    print('PASS dot-prefixed list components and root component refused with stand-in HOME')


def blocks_png(n):
    from verify_site_tools import chunk
    bits = [bit for _ in range(n) for bit in (0, 1, 0, 0, 0, 0, 0, 0, 0, 0)]
    bits += [1, 0, 0]
    bits += [0] * (-len(bits) % 8)
    packed = bytes(sum(bits[i+j] << j for j in range(8)) for i in range(0, len(bits), 8))
    raw = bytes((0, 16, 32, 48, 255))
    stream = bytes((120, 1)) + packed + struct.pack('<HH', 5, 65530) + raw + struct.pack('>I', zlib.adler32(raw))
    assert zlib.decompress(stream) == raw
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', stream) + chunk(b'IEND', b''))


def blocks(work):
    from verify_site_tools import compile_tool
    exe = compile_tool(ROOT / 'tools/site_images.c0', 'images', work)
    image = work / 'blocks.png'
    out = work / 'out.spr'
    image.write_bytes(blocks_png(50000))
    start = time.monotonic()
    result = subprocess.run([str(exe), str(image), str(out)], capture_output=True, text=True, timeout=3)
    elapsed = time.monotonic() - start
    assert result.returncode != 0 and 'deflate block budget' in result.stdout, result
    print(f'PASS 50000 empty fixed blocks refused in {elapsed:.3f} seconds')
    image.write_bytes(blocks_png(12))
    result = subprocess.run([str(exe), str(image), str(out)], capture_output=True, text=True, timeout=3)
    assert result.returncode == 0, result
    assert out.read_bytes() == struct.pack('<qqq', 1, 1, 1) + bytes((48, 32, 16, 255))
    print('PASS normal multi-block PNG pixel oracle')


if __name__ == '__main__':
    cases = sys.argv[1:] or ['privacy', 'ddc', 'dots', 'blocks']
    with tempfile.TemporaryDirectory(prefix='site-home-') as HOME_FIXTURE, tempfile.TemporaryDirectory(prefix='site-followup-', dir='/tmp') as temporary:
        work = Path(temporary)
        for case in cases:
            if case == 'privacy':
                privacy()
            else:
                globals()[case](work)
