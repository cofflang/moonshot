#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# Local fault controls are inserted only in the test candidate and restored on exit.
import argparse
import hashlib
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--cases', nargs='+', choices=['matrix', 'pftext', 'gpout', 'grow', 'neighbor', 'blitfault', 'presentfault', 'fdgrow'],
                    default=['matrix', 'pftext', 'gpout', 'grow', 'neighbor', 'blitfault', 'presentfault', 'fdgrow'])
parser.add_argument('--mutation', choices=['matrix', 'abort', 'cleanup', 'irq', 'sound', 'padding'])
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
paths = [ROOT / 'kernel/core/syscall.c0', ROOT / 'tests/elf/29_hostile_syscalls.c0', ROOT / 'kernel/drivers/oljud.c0']
original = {p: p.read_bytes() for p in paths}
manifest = ROOT / 'tests/elf/manifest.txt'
original[manifest] = manifest.read_bytes()


def require_replace(text, old, new):
    assert text.count(old) == 1, (old, text.count(old))
    return text.replace(old, new, 1)


def build():
    with (args.output / 'build.log').open('wb') as log:
        subprocess.run([str(ROOT / 'build.sh')], cwd=ROOT, stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=300)


def boot(case, iso, work):
    mode = {'matrix': 0, 'pftext': 1, 'gpout': 2, 'grow': 3, 'neighbor': 4, 'blitfault': 5, 'presentfault': 6, 'fdgrow': 7}[case]
    serial = args.output / (case + '.log')
    monitor = work / 'monitor.sock'
    disk = work / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(10485760)
    process = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(iso),
        '-drive', f'file={disk},format=raw,if=ide,index=0,media=disk',
        '-serial', 'file:' + str(serial), '-display', 'none', '-no-reboot',
        '-m', '128', '-nic', 'none', '-audiodev', 'none,id=snd0',
        '-device', 'sb16,audiodev=snd0', '-monitor', f'unix:{monitor},server,nowait'],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        deadline = time.monotonic() + 30
        while not monitor.exists():
            if process.poll() is not None:
                raise RuntimeError(process.stderr.read().decode())
            if time.monotonic() > deadline:
                raise RuntimeError('monitor timeout')
            time.sleep(.1)
        sock.connect(str(monitor))
        sock.setblocking(False)

        def send(command):
            sock.sendall((command + '\n').encode())
            time.sleep(.05)
            try:
                sock.recv(65536)
            except BlockingIOError:
                pass

        def word(text):
            keys = {' ': 'spc', '.': 'dot', '/': 'slash', '-': 'minus'}
            for char in text:
                send('sendkey ' + keys.get(char, char))
                time.sleep(.04)

        def read():
            return serial.read_text(errors='replace') if serial.exists() else ''

        time.sleep(3)
        word('root'); send('sendkey ret'); time.sleep(.5)
        send('sendkey ret'); time.sleep(1.5)
        start = len(read())
        word(f'start test/et29.elf {mode}'); send('sendkey ret')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            text = read()[start:]
            if ('KERNEL PANIC' in text or '[copytest] semantics pass' in text
                    or '[copytest] reaper empty pass' in text):
                break
            time.sleep(.1)
        time.sleep(.3)
        text = read()[start:]
        panic = 'KERNEL PANIC' in text
        if not panic:
            send('sendkey alt-tab'); time.sleep(.3)
            send('sendkey alt-w'); time.sleep(.4)
            word('echo copy alive'); send('sendkey ret'); time.sleep(1)
            text = read()[start:]
        (args.output / (case + '-run.log')).write_text(text)
        if case == 'neighbor':
            ok = panic and 'unguarded kernel page fault' in text and '[usercopy] stopped' not in text
        elif case == 'matrix':
            ok = ('[copytest] matrix pass' in text and '[copytest] semantics pass' in text
                  and '[sh] copy alive' in text and not panic)
        else:
            vector = 13 if case == 'gpout' else 14
            ok = (f'vector={vector}' in text and '[usercopy] stopped task ' in text
                  and '[copytest] accounting metadata pass' in text
                  and '[copytest] cleanup pass' in text and '[copytest] reaper empty pass' in text
                  and '[sh] copy alive' in text and not panic
                  and '[copytest] unexpectedly returned' not in text)
        print(f'{case}: {"PASS" if ok else "FAIL"}', flush=True)
        return ok
    finally:
        sock.close()
        if process.poll() is None:
            process.terminate()
        process.communicate(timeout=10)
        monitor.unlink(missing_ok=True)


try:
    source = original[paths[0]].decode()
    controls = (ROOT / 'tests/fixtures/user_copy_controls.c0').read_text()
    source = require_replace(source, '    store64(c, 1);\n    return c;',
        '    store64(c, 1);\n    copy_test_begin(c, p);\n    return c;')
    source = source.replace('access(p);', 'access(copy_test_address(p));')
    source = source.replace('access(p, v);', 'access(copy_test_address(p), v);')
    source = source.replace('access(p + i)', 'access(copy_test_address(p + i))')
    source = source.replace('access(p + i, load8(src + i))',
                            'access(copy_test_address(p + i), load8(src + i))')
    source = require_replace(source, '    user_cleanup(me);',
        '    copy_test_abort();\n    user_cleanup(me);')
    source = require_replace(source, '    if (ptr) {\n        if (kind == 1)',
        '    if (ptr) {\n        if (sched_current == copy_test_tid) { copy_test_frees += 1; }\n        if (kind == 1)')
    source = require_replace(source, '        klick_drop();\n    }\n    return;\n}\n\n// The descriptor',
        '        klick_drop();\n    }\n    copy_test_cleanup(tid);\n    return;\n}\n\n// The descriptor')
    anchor = '    user_assert_irq_off("sys_dispatch");'
    assert anchor in source
    source = source.replace(anchor, anchor + '''
    if (num == 32752) { return copy_test_matrix(a1); }
    if (num == 32753) { return copy_test_arm(a1, a2, a3); }
''', 1)
    if args.mutation == 'matrix':
        source = source.replace('int need = 5;', 'int need = 1;').replace('if (write) { need = 7; }', 'if (write) { need = 3; }')
    if args.mutation == 'abort':
        source = source.replace('    if (vector != 13 && vector != 14) { return 0; }',
                                '    return 0;\n    if (vector != 13 && vector != 14) { return 0; }', 1)
    if args.mutation == 'cleanup':
        source = require_replace(source, '    copy_test_abort();\n    user_cleanup(me);',
                                 '    copy_test_abort();')
    if args.mutation == 'irq':
        source = require_replace(source, 'int user_begin(int p, int n, int write) {',
            'int user_begin(int p, int n, int write) {\n    int on_test = enable_interrupts; on_test();')
    # A deliberate access in c0 is adjacent in the caller but outside the registered site.
    source = require_replace(source, '    int access = user_access_read;\n    int v = access',
        '    if (copy_test_mode == 4 && p == copy_test_ptr) { load8(0x900000000); }\n    int access = user_access_read;\n    int v = access')
    # The console bulk path supplies the neighboring unregistered control.
    source = require_replace(source, '    int access = user_copy_read;\n    access(dst, p, n);',
        '    if (copy_test_mode == 4 && p == copy_test_ptr) { load8(0x900000000); }\n    int access = user_copy_read;\n    access(dst, p, n);')
    if args.mutation == 'padding':
        source = require_replace(source, '            for (clear19 = 0; clear19 < 48; clear19 += 1) { store8(rec + clear19, 0); }', '')
    if args.mutation == 'sound':
        sound = original[paths[2]].decode()
        sound = require_replace(sound, 'if (buf == 0 && len < 0) { return oljud_flush(tid); }',
                                 'if (buf == 0 && len < 0) { return 0 - 1; }')
        paths[2].write_text(sound)
    paths[0].write_text(source + '\n' + controls)
    paths[1].write_bytes((ROOT / 'tests/fixtures/user_copy.c0').read_bytes())
    build()
    with tempfile.TemporaryDirectory(prefix='moonshot-copy-') as temp:
        work = Path(temp)
        isodir = work / 'iso'
        (isodir / 'boot/grub').mkdir(parents=True)
        shutil.copyfile(ROOT / 'build/moonshot.elf', isodir / 'boot/moonshot.elf')
        shutil.copyfile(ROOT / 'kernel/core/grub_test.cfg', isodir / 'boot/grub/grub.cfg')
        iso = work / 'moonshot.iso'
        with (args.output / 'iso.log').open('wb') as log:
            subprocess.run(['grub-mkrescue', '-o', str(iso), str(isodir)],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        results = [boot(case, iso, work) for case in args.cases]
        raise SystemExit(0 if all(results) else 1)
finally:
    for path, contents in original.items():
        path.write_bytes(contents)
    (args.output / 'source-sha256.txt').write_text(''.join(
        hashlib.sha256(contents).hexdigest() + '  ' + str(path.relative_to(ROOT)) + '\n'
        for path, contents in original.items()))
