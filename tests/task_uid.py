#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
"""Run a guest process across root activity and check child credentials."""
import pathlib
import select
import shutil
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'out/task-uid'
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
def wait_for(marker, start=0, seconds=35):
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
keys = {' ': 'spc', '.': 'dot', '/': 'slash', '-': 'minus', '\n': 'ret'}
def type_line(line):
    for char in line + '\n':
        q.stdin.write(('sendkey ' + keys.get(char, char) + '\n').encode())
        q.stdin.flush(); response(); time.sleep(.065)
    time.sleep(.15)
def command(line, marker='[sh] prompt'):
    start = len(text()); type_line(line); wait_for(marker, start)
try:
    response(); wait_for('[sched] starting')
    type_line('root'); type_line(''); wait_for("username='root' uid=0 ok=1")
    command('passwd', 'old password: ')
    command('', 'new password: ')
    command('rootsecret', 'again: ')
    command('rootsecret')
    command('write uid-secret.txt secret')
    command('mode uid-secret.txt locked')
    command('write uid-victim.txt rootdata')
    command('login guest', 'password: '); command('')
    # Task 4 is the shell task, a kernel task of uid 0 that serves every window.
    command('kill 4', '[sh] kill: permission denied\n')
    command('whoami', '[sh] guest\n')
    command('start test/et32.elf guest')
    wait_for('[uid-test] waiting for root activity')
    command('login root', 'password: '); command('rootsecret')
    command('whoami', '[sh] root\n')
    wait_for('[uid-test] DONE')
    wait_for('[sh] guest\n')
    # The probe's SYS_SHELL window runs as guest, but the probe's own window
    # did not have the focus, so the new window does not take it and root
    # keeps typing in its own window.
    command('whoami', '[sh] root\n')
    command('login root', 'password: '); command('rootsecret')
    command('start test/et32.elf root')
    wait_for('[uid-test] PASS root control')
finally:
    q.terminate()
    try: q.wait(timeout=5)
    except subprocess.TimeoutExpired: q.kill(); q.wait()
result = text()
lines = [line for line in result.splitlines() if line.startswith('[uid-test]')]
print('\n'.join(lines))
assert not any('FAIL' in line for line in lines), 'credential isolation failed'
for marker in ['PASS guest permissions', 'PASS creator read and write',
               'PASS child permissions', 'PASS spawn inheritance', 'PASS root control', 'DONE']:
    assert '[uid-test] ' + marker in result, marker
assert not any('jakel_current_uid' in p.read_text() for p in (root / 'kernel').rglob('*.c0'))
print('PASS task identity survives root activity, spawn and shell creation')
