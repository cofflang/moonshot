#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
"""A build reads only files its user or root owns, however coff is started."""
import pathlib
import select
import shutil
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'out/build-inputs'
out.mkdir(parents=True, exist_ok=True)
with (out / 'build.log').open('w') as log:
    subprocess.run([str(root / 'build.sh')], cwd=root, check=True,
                   stdout=log, stderr=subprocess.STDOUT)
iso = out / 'iso'
(iso / 'boot/grub').mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'build/moonshot.elf', iso / 'boot/moonshot.elf')
shutil.copyfile(root / 'kernel/core/grub_test.cfg', iso / 'boot/grub/grub.cfg')
with (out / 'grub.log').open('w') as log:
    subprocess.run(['grub-mkrescue', '-o', str(out / 'test.iso'), str(iso)],
                   check=True, stdout=log, stderr=subprocess.STDOUT)
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
        if marker in text()[start:]: return True
        time.sleep(.05)
    return False
def response():
    data = b''
    while b'(qemu)' not in data:
        assert select.select([q.stdout], [], [], 5)[0], 'monitor timeout'
        part = q.stdout.read1(65536)
        assert part, 'monitor exited'
        data += part
keys = {' ': 'spc', '.': 'dot', '/': 'slash', '-': 'minus', '\n': 'ret',
        ';': 'semicolon', '"': 'shift-apostrophe', '(': 'shift-9', ')': 'shift-0',
        '{': 'shift-bracket_left', '}': 'shift-bracket_right', '*': 'shift-8'}
def key(k):
    q.stdin.write(('sendkey ' + k + '\n').encode()); q.stdin.flush()
    response(); time.sleep(.065)
def type_text(s):
    for c in s: key(keys.get(c, c))
def command(line, marker='[sh] prompt', seconds=40):
    start = len(text()); type_text(line); key('ret')
    assert wait_for(marker, start, seconds), 'timed out after ' + line
    return start
def login(name):
    command('login ' + name, 'password: '); command('')
results = []
def check(ok, label):
    results.append(ok)
    print(('PASS ' if ok else 'FAIL ') + label)
try:
    response(); assert wait_for('[sched] starting', 0, 60)
    type_text('root'); key('ret'); key('ret')
    assert wait_for("username='root' uid=0 ok=1", 0, 20)
    command('make gdir')
    command('own gdir guest')
    login('guest')
    command('write util.c0 int util() { return 7; }')
    command('write gdir/.skrift-eval.c0 int main() { return 99; }')
    command('write gutil.c0 int gutil() { return 9; }')
    command('write gs.s nop')
    command('write gprog.c0 include "gutil.c0"; int main() { return gutil(); }')
    s = command('execute gprog.c0', '[syscall] exit code=', 60)
    check(wait_for('[syscall] exit code=9\n', s, 10), 'a user builds with an include of their own')
    login('root')
    # skrift's F6 in a folder another user owns, with that user's
    # .skrift-eval.c0 already there. Done first, while there is room for
    # skrift's window, and closed with Alt+W after.
    command('change gdir')
    start = len(text())
    type_text('edit calc.c0'); key('ret'); time.sleep(3)
    type_text('6 * 7'); key('f6'); time.sleep(10)
    after = text()[start:]
    check('[syscall] build refused a file another user owns' in after
          and '[syscall] exit code=42' not in after
          and '[syscall] exit code=99' not in after
          and 'skrift: no window' not in after,
          'skrift F6 as root in a guest folder builds nothing')
    key('alt-w'); time.sleep(1.0); key('alt-w'); time.sleep(1.5)
    command('change /')
    command('write prog.c0 include "util.c0"; int main() { return util(); }')
    s = command('execute prog.c0', '[sh] prompt', 60)
    time.sleep(2)
    check('[syscall] build refused a file another user owns' in text()[s:]
          and '[sh] execute: coff could not compile prog.c0' in text()[s:]
          and '[syscall] exit code=7' not in text()[s:],
          'root does not build with an include another user made')
    command('write rutil.c0 int rutil() { return 8; }')
    command('write rprog.c0 include "rutil.c0"; int main() { return rutil(); }')
    s = command('execute rprog.c0', '[syscall] exit code=', 60)
    check(wait_for('[syscall] exit code=8\n', s, 10), 'root builds with an include of its own')
    command('own util.c0 root')
    s = command('execute prog.c0', '[syscall] exit code=', 60)
    check(wait_for('[syscall] exit code=7\n', s, 10), 'root builds once it owns the library')
    # Root's own include inside a folder another user owns. Only the folder
    # part of the chain rule refuses it, and the build passes again once
    # root owns the folder.
    command('make gd2')
    command('write gd2/rlib.c0 int rlib() { return 5; }')
    command('own gd2 guest')
    command('write cprog.c0 include "gd2/rlib.c0"; int main() { return rlib(); }')
    s = command('execute cprog.c0', '[sh] prompt', 60)
    time.sleep(2)
    check('[syscall] build refused a file another user owns' in text()[s:]
          and '[sh] execute: coff could not compile cprog.c0' in text()[s:]
          and '[syscall] exit code=5' not in text()[s:],
          'root does not build with its own include inside a guest folder')
    command('own gd2 root')
    s = command('execute cprog.c0', '[syscall] exit code=', 60)
    check(wait_for('[syscall] exit code=5\n', s, 10), 'root builds once it owns the folder')
    # smed is a build too. Root's smed does not read the guest's assembly,
    # and reads root's own.
    s = command('start /smed.elf gs.s gs.elf', '[syscall] exit code=', 60)
    time.sleep(1)
    check('[syscall] build refused a file another user owns' in text()[s:],
          "root's smed does not read assembly another user wrote")
    command('write rs.s nop')
    s = command('start /smed.elf rs.s rs.elf', '[syscall] exit code=', 60)
    time.sleep(1)
    check('[syscall] build refused a file another user owns' not in text()[s:],
          "root's smed reads its own assembly")
finally:
    q.terminate()
    try: q.wait(timeout=5)
    except subprocess.TimeoutExpired: q.kill(); q.wait()
assert results and all(results), 'build inputs'
print('PASS builds read only their own user\'s and root\'s files')
