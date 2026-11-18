#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
"""Check that no task holds interrupts off for more than the serial bound."""
import os
import pathlib
import re
import select
import shutil
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'out/serial-bound'
out.mkdir(parents=True, exist_ok=True)
# A debug build, the only kind with the serialmax command, from a copy of
# the tree so build/ keeps the ordinary kernel.
scratch = pathlib.Path(tempfile.mkdtemp(prefix='moonshot-serial-bound.'))
tree = scratch / 'moonshot'
tree.mkdir()
for name in ['kernel', 'programs', 'tools', 'tests']:
    shutil.copytree(root / name, tree / name, symlinks=True)
for name in ['build.sh', 'toolchain.sha256']:
    shutil.copy2(root / name, tree / name)
for sibling in ['c0-coff', 'gnista', 'utsikt']:
    if (root.parent / sibling).exists():
        (scratch / sibling).symlink_to(root.parent / sibling)
try:
    with (out / 'build.log').open('w') as log:
        subprocess.run([str(tree / 'build.sh')], cwd=tree, stdout=log,
                       stderr=subprocess.STDOUT, check=True,
                       env=dict(os.environ, MOONSHOT_DEBUG='1'))
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
                      '-no-reboot', '-m', '128', '-monitor', 'stdio'],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def text():
    return serial.read_text(errors='replace')
def wait_for(marker, start=0, seconds=40):
    end = time.monotonic() + seconds
    while time.monotonic() < end and q.poll() is None:
        if marker in text()[start:]: return
        time.sleep(.05)
    raise AssertionError('timed out waiting for ' + marker)
def response():
    data = b''
    while b'(qemu)' not in data:
        assert select.select([q.stdout], [], [], 5)[0], 'monitor timeout'
        part = q.stdout.read1(65536)
        assert part, 'monitor exited'
        data += part
keys = {' ': 'spc', '.': 'dot', '-': 'minus', '\n': 'ret'}
def type_line(line):
    for char in line + '\n':
        q.stdin.write(('sendkey ' + keys.get(char, char) + '\n').encode())
        q.stdin.flush(); response(); time.sleep(.03)
def command(line, marker='[sh] prompt'):
    start = len(text()); type_line(line); wait_for(marker, start)
try:
    response(); wait_for('[sched] starting')
    type_line('root'); type_line(''); wait_for("username='root' uid=0 ok=1")
    # A long file through echo, and a typed line near the shell's limit.
    command('echo --file about.html')
    command('echo ' + 'a' * 115)
    # A shell line longer than the bound, through the serial mirror.
    command('mirrorlong')
    start = len(text())
    type_line('serialmax')
    wait_for(' bytes, bound ', start)
    # Another writer joins the mirror in the middle of a long line.
    inject_from = len(text())
    command('mirrorinject')
finally:
    q.terminate()
    try: q.wait(timeout=5)
    except subprocess.TimeoutExpired: q.kill(); q.wait()
log = text()
line = [l for l in log.splitlines() if l.startswith('[sh] serialmax ')][-1]
print(line)
first = log.index('[echo] ')
echoed = len(log[first:log.index('[sh] prompt', first)])
print('echo --file wrote', echoed, 'bytes to serial')
longest = int(line.split()[2])
bound = int(line.split()[5])
# The bound is checked after each byte, and a piece written without a check
# after it (a literal of a few bytes) can follow, so a little over is fine.
assert echoed > 4 * bound, 'the file was too short to test the bound'
# A line longer than the bound may be split at a room point by a line from
# the scheduler, a syscall or the timer, which then sits inside it. Those
# lines are taken out before the long line is compared.
def unsplit(t):
    return re.sub(r'(\[sched\] |\[syscall\] |tick \d)[^\n]*\n', '', t)
assert '[sh] ' + 'm' * 200 + '\n' in unsplit(log), 'the long mirror line lost or gained bytes'
assert longest <= bound + 16, 'a task held interrupts off for %d bytes' % longest
print('PASS no task section wrote more than the bound with interrupts off')
joined = log[inject_from:]
assert joined.count('injected') == 1, 'the other writer\'s line was lost or doubled'
mixed = unsplit(joined).replace('[sh] injected\n', '', 1)
assert '[sh] ' + 'm' * 200 + '\n' in mixed, 'the long line lost or gained bytes when another writer joined'
print('PASS a line another writer joins keeps every byte once, and so does the other line')
