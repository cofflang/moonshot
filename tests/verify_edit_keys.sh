#!/usr/bin/env bash
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
# Types the shell's editing keys through QEMU's keyboard, Up, Down, Left,
# Right, Home, End and Ctrl+A, E, W, K and U, and checks the line each one
# leaves by what the shell runs. A key that sends the wrong editing action
# leaves a different line.
set -eu
cd "$(dirname "$0")/.."
out=out/edit-keys
mkdir -p "$out/iso/boot/grub"
./build.sh > "$out/build.log" 2>&1
cp build/moonshot.elf "$out/iso/boot/moonshot.elf"
cp kernel/core/grub_test.cfg "$out/iso/boot/grub/grub.cfg"
grub-mkrescue -o "$out/test.iso" "$out/iso" > "$out/grub.log" 2>&1
python3 - "$out" <<'EOF'
import pathlib, select, subprocess, sys, time
d = pathlib.Path(sys.argv[1])
serial = d / 'serial.log'
serial.write_bytes(b'')
q = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(d / 'test.iso'),
                      '-serial', 'file:' + str(serial), '-display', 'none',
                      '-no-reboot', '-m', '128', '-monitor', 'stdio'],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def text():
    return serial.read_text(errors='replace')
def wait_for(marker, start=0, seconds=35):
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
names = {' ': 'spc', '.': 'dot', '/': 'slash', '-': 'minus'}
def key(k):
    q.stdin.write(('sendkey ' + k + '\n').encode()); q.stdin.flush()
    response(); time.sleep(.065)
def type_text(s):
    for c in s: key(names.get(c, c))
failures = []
def check(seq, expect, label):
    start = len(text())
    for item in seq:
        if isinstance(item, tuple): key(item[0])
        else: type_text(item)
    key('ret')
    ok = wait_for('[sh] ' + expect + '\n', start, 10)
    wait_for('[sh] prompt', start, 5)
    print(('PASS ' if ok else 'FAIL ') + label)
    if not ok: failures.append(label)
try:
    response()
    assert wait_for('[sched] starting', 0, 60), 'no boot'
    type_text('root'); key('ret'); key('ret')
    assert wait_for('ok=1', 0, 20), 'no login'
    time.sleep(.5)
    # Each line run is a history entry, newest last.
    check(['echo aa'], 'aa', 'a typed line runs')
    check(['echo bb'], 'bb', 'a second typed line runs')
    check([('up',)], 'bb', 'Up recalls the newest entry')                 # aa bb bb
    check([('up',), ('up',), ('up',)], 'aa', 'Up walks to older entries')  # aa bb bb aa
    check([('up',), ('up',), ('down',)], 'aa', 'Down walks back to newer entries')
    check(['echo ckjunk', ('left',), ('left',), ('left',), ('left',), ('ctrl-k',)], 'ck',
          'Left moves the cursor and Ctrl+K cuts to the end')
    check(['garbage', ('ctrl-u',), 'echo cu'], 'cu', 'Ctrl+U cuts to the start')
    check(['cho ca', ('ctrl-a',), 'e'], 'ca', 'Ctrl+A goes to the start')
    check(['echo c', ('ctrl-a',), ('ctrl-e',), 'e'], 'ce', 'Ctrl+E goes to the end')
    check(['cho h', ('home',), 'e', ('end',), 'x'], 'hx', 'Home and End')
    check(['echo foo bar', ('ctrl-w',), 'baz'], 'foo baz', 'Ctrl+W deletes the word before the cursor')
    check(['echo ab', ('left',), ('right',), 'c'], 'abc', 'Right moves the cursor back')
finally:
    q.terminate()
    try: q.wait(timeout=5)
    except subprocess.TimeoutExpired: q.kill(); q.wait()
if failures:
    print('FAIL: editing keys ' + ', '.join(failures))
    sys.exit(1)
print('PASS: every editing key reaches the shell as its own action')
EOF
