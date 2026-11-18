#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
"""utsikt runs a page's scripts only when the opener or root owns the page."""
import pathlib
import select
import shutil
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'out/page-scripts'
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
keys = {' ': 'spc', '.': 'dot', '/': 'slash', '-': 'minus', ';': 'semicolon',
        '"': 'shift-apostrophe', '(': 'shift-9', ')': 'shift-0', '<': 'shift-comma',
        '>': 'shift-dot', '=': 'equal', ':': 'shift-semicolon', '#': 'shift-3',
        '{': 'shift-bracket_left', '}': 'shift-bracket_right'}
def key(k):
    q.stdin.write(('sendkey ' + k + '\n').encode()); q.stdin.flush()
    response(); time.sleep(.065)
def type_text(s):
    for c in s:
        if c.isupper(): key('shift-' + c.lower())
        else: key(keys.get(c, c))
def command(line, marker='[sh] prompt', seconds=40):
    start = len(text()); type_text(line); key('ret')
    assert wait_for(marker, start, seconds), 'timed out after ' + line
    return start
def login(name):
    command('login ' + name, 'password: '); command('')
def page(name, mark):
    return ('write ' + name + ' <p>page</p><script type="text/x-glimt">log("'
            + mark + '");</script>')
def open_page(name):
    start = len(text())
    type_text('start utsikt.elf ' + name); key('ret'); time.sleep(5)
    seen = text()[start:]
    # start leaves the focus on the shell, so the page's window is taken
    # with Alt+Tab before Alt+W closes it.
    key('alt-tab'); time.sleep(.5)
    key('alt-w'); time.sleep(1.5)
    return seen
def monitor(cmd, settle=.06):
    q.stdin.write((cmd + '\n').encode()); q.stdin.flush()
    response(); time.sleep(settle)
def shot(name, settle=.9):
    path = out / name
    if path.exists(): path.unlink()
    monitor('screendump ' + str(path), settle)
    return read_ppm(path)
def read_ppm(path):
    data = path.read_bytes()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos + 1].isspace(): pos += 1
        start = pos
        while not data[pos:pos + 1].isspace(): pos += 1
        fields.append(int(data[start:pos]))
    return fields[0], fields[1], data[pos + 1:]
def tavla(img):
    # The window opened with start is the right half of the screen, so the
    # shell beside it stays out of every count.
    w, h, buf = img
    for y in range(14, h - 14):
        for x in range(w // 2, w):
            off = (y * w + x) * 3
            yield x, y, (buf[off], buf[off + 1], buf[off + 2])
# The mouse is relative. It is parked at the origin by moving further than
# the screen in both axes, then moved by tracked steps.
def click(x, y):
    for _ in range(9): monitor('mouse_move -100 -100', .04)
    px = py = 0
    while px != x or py != y:
        dx = max(-100, min(100, x - px)); dy = max(-100, min(100, y - py))
        monitor('mouse_move %d %d' % (dx, dy), .04); px += dx; py += dy
    # utsikt follows a link on the press edge, so the captures start at
    # once, while the next page is still being built behind the old one.
    monitor('mouse_button 1', 0)
    shots = [shot('link_%d_after.ppm' % i, 0) for i in range(1, 9)]
    monitor('mouse_button 0', .35)
    time.sleep(2)
    shots.append(shot('link_9_after.ppm'))
    return shots
LINK_RGB = (0, 64, 192)       # a{color:#0040c0} in utsikt's default sheet
FAR_BG = (232, 224, 244)      # gfor.html's body background #e8e0f4
CONSOLE_FG = (200, 200, 200)  # FB_FG, what print() draws into a window
results = []
def check(ok, label):
    results.append(ok)
    print(('PASS ' if ok else 'FAIL ') + label)
try:
    response(); assert wait_for('[sched] starting', 0, 60)
    type_text('root'); key('ret'); key('ret')
    assert wait_for("username='root' uid=0 ok=1", 0, 20)
    command(page('rpage.html', 'rootpageran'))
    login('guest')
    command(page('gpage.html', 'guestpageran'))
    # The shell takes lines of up to 127 bytes, so this page is written tight.
    command('write gfor.html <style>body{background:#e8e0f4}</style><body>far'
            '<script type="text/x-glimt">log("glinkran");</script>')
    seen = open_page('gpage.html')
    check('guestpageran' in seen and 'without its scripts' not in seen,
          "a user's own page runs its script")
    seen = open_page('rpage.html')
    check('rootpageran' in seen, "a root page's script runs for a user")
    login('root')
    seen = open_page('gpage.html')
    check('guestpageran' not in seen
          and "utsikt: another user's page, shown without its scripts" in seen
          and 'showing the built-in page' not in seen,
          "root opens a user's page without running its script")
    seen = open_page('rpage.html')
    check('rootpageran' in seen, "root's own page runs its script")
    # A link from root's own page to the guest's page. The foreign page is
    # reached from inside utsikt's event loop, after the first frame, where
    # nothing may be printed, since print() draws into the window over the
    # page. The window is captured as a time series from the click on.
    command('write rlink.html <p><a href="gfor.html">far</a></p>')
    start = len(text())
    type_text('start utsikt.elf rlink.html'); key('ret'); time.sleep(5)
    key('alt-tab'); time.sleep(1.5)
    first = shot('link_0_before.ppm')
    links = [(x, y) for x, y, c in tavla(first) if c == LINK_RGB]
    console_before = sum(1 for _, _, c in tavla(first) if c == CONSOLE_FG)
    check(bool(links), 'the link on the owned page is on screen')
    if links:
        xs = [x for x, _ in links]; ys = [y for _, y in links]
        clicked = len(text())
        series = click((min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2)
        after = text()[clicked:]
        far = []
        stray = []
        for img in series:
            n = total = console = 0
            for _, _, c in tavla(img):
                total += 1
                if c == FAR_BG: n += 1
                if c == CONSOLE_FG: console += 1
            far.append(n / total); stray.append(console)
        print('after the click, foreign page share %s, console-text pixels '
              '%s (before %d)' % (['%.2f' % f for f in far], stray,
                                  console_before))
        check(far[-1] >= .4, 'the link leads to the guest page')
        check('glinkran' not in after and 'glimt:' not in after,
              "the guest page reached by a link runs no script for root")
        check(all(c <= console_before for c in stray),
              'nothing is printed over the page after the first frame')
        check("another user's page" not in after,
              'the foreign-page note is not printed after the first frame')
    key('alt-w'); time.sleep(1.5)
finally:
    q.terminate()
    try: q.wait(timeout=5)
    except subprocess.TimeoutExpired: q.kill(); q.wait()
assert results and all(results), 'page scripts'
print('PASS page scripts run only from the opener\'s and root\'s pages')
