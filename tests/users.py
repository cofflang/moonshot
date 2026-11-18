#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
"""Run account regressions inside the kernel on an isolated test image."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'out/users'
out.mkdir(parents=True, exist_ok=True)
# The probe is built from a copy of the tree, so the knekt.c0 a build or an
# editor sees in the tree is never the patched one, even when this is
# stopped halfway.
scratch = pathlib.Path(tempfile.mkdtemp(prefix='moonshot-users.'))
tree = scratch / 'moonshot'
tree.mkdir()
for name in ['kernel', 'programs', 'tools', 'tests']:
    shutil.copytree(root / name, tree / name, symlinks=True)
for name in ['build.sh', 'toolchain.sha256']:
    shutil.copy2(root / name, tree / name)
for sibling in ['c0-coff', 'gnista', 'utsikt']:
    if (root.parent / sibling).exists():
        (scratch / sibling).symlink_to(root.parent / sibling)
knekt = tree / 'kernel/core/knekt.c0'
original = knekt.read_bytes()
marker = b'    boot_log_persist();\n'
assert original.count(marker) == 1
fixture = (root / 'tests/fixtures/users.c0').read_bytes()
if os.environ.get('USERS_AUTH_ONLY'):
    fixture = fixture.split(b'void users_files_probe()')[0].replace(b'    users_files_probe();\n', b'').replace(b'    users_input_probe();\n', b'').replace(b'    users_close_probe();\n', b'').replace(b'    users_language_probe();\n', b'')
try:
    knekt.write_bytes(original.replace(marker, marker + b'    if (boot_test) { users_probe(); }\n') +
                      fixture)
    with (out / 'build.log').open('w') as log:
        subprocess.run([str(tree / 'build.sh')], cwd=tree, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    shutil.copyfile(tree / 'build/moonshot.elf', out / 'moonshot.elf')
finally:
    shutil.rmtree(scratch)
iso = out / 'iso'
(iso / 'boot/grub').mkdir(parents=True, exist_ok=True)
shutil.copyfile(out / 'moonshot.elf', iso / 'boot/moonshot.elf')
shutil.copyfile(root / 'kernel/core/grub_test.cfg', iso / 'boot/grub/grub.cfg')
with (out / 'grub.log').open('w') as log:
    subprocess.run(['grub-mkrescue', '-o', str(out / 'test.iso'), str(iso)],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
serial = out / 'serial.log'
serial.write_bytes(b'')
q = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(out / 'test.iso'),
                      '-serial', 'file:' + str(serial), '-display', 'none',
                      '-no-reboot', '-m', '128'])
try:
    end = time.monotonic() + 90
    while time.monotonic() < end and q.poll() is None:
        if b'[users-test] DONE' in serial.read_bytes():
            break
        time.sleep(.1)
finally:
    q.terminate()
    try:
        q.wait(timeout=5)
    except subprocess.TimeoutExpired:
        q.kill(); q.wait()
lines = [line for line in serial.read_text(errors='replace').splitlines()
         if line.startswith(('[users-test]', 'KERNEL PANIC'))]
print('\n'.join(lines))
assert lines and lines[-1] == '[users-test] DONE', 'probe did not finish'
assert not any(line.startswith('KERNEL PANIC') for line in lines), 'kernel panic'
assert not any('FAIL' in line for line in lines), 'account regression'

# Refusals name their real reason.
text = serial.read_text(errors='replace')
for message in ['make: only root may put a folder in the root folder',
                'rename: only root may put a folder in the root folder',
                'kill: permission denied',
                'write: file belongs to guest, remove it first',
                'copy: file belongs to guest, remove it first',
                'execute: users-hello.elf belongs to guest, remove it first',
                'start: users-calc.elf belongs to guest, not started',
                'run: users-setup.sk belongs to guest, not run',
                'the working folder is gone, back in /',
                'interpret: users-g.c0 belongs to guest, not run',
                'interpret: folder users-gd belongs to guest, not run',
                'execute: users-g.c0 belongs to guest, not compiled']:
    assert '[sh] ' + message + '\n' in text, 'missing refusal: ' + message
print('PASS refusals are honest')

# Secret prompt events bracket the numeric key echo diagnostics.
import re
masked = False
for line in serial.read_text(errors='replace').splitlines():
    if line.startswith('[auth] '): masked = True
    if line.startswith('[sh] '): masked = False
    if masked and ' typed:' in line:
        match = re.search(r'char=(\d+)', line)
        assert match and int(match[1]) in (10, 42), 'secret key leaked to serial'
print('PASS secret key diagnostics are masked')

keyboard = (root / 'kernel/drivers/keyboard.c0').read_text()
assert 'serial_print_int(scancode)' not in keyboard, 'raw scan codes expose secrets'
