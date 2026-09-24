#!/usr/bin/env bash
#
# verify_utsikt_links.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that utsikt FOLLOWS a link: that clicking painted words loads a
# different file off jakel and renders it, and that Backspace comes back.
#
# Four separate claims sit behind one click, and the script is built so that
# each of them can fail on its own:
#
#   1. The parser kept the href. Nothing on screen says so directly, but a
#      link is painted in the default stylesheet's link colour and underlined
#      by the paint pass, and neither happens for a run with no target. The
#      script FINDS the link by that colour rather than by hardcoded
#      coordinates, so a link that never became a link is a failure to locate
#      one, not a click that misses.
#   2. The engine knows where it painted those words. The click lands at the
#      centre of the located run, which only reaches utsikt's hit test if the
#      rectangle recorded at paint time matches the pixels.
#   3. Following it reads DIFFERENT BYTES. about.html's background colour
#      appears in no other page and in no other part of the system, so
#      counting pixels of it says which document is on screen without reading
#      any text.
#   4. Backspace pops the history. The first page has to come back, which is
#      a second load rather than an undo of the first.
#
# The mouse is driven through QEMU's monitor (`mouse_move`, `mouse_button`),
# the same path verify_klick.sh and verify_mouse.sh use. The device is
# relative, so the pointer is first parked at the origin by moving further
# than the screen is wide in both axes, which klick clamps, and absolute
# positions are then reached by tracked deltas.
#
# Validated by breaking it, twice, at the two ends of the chain:
#   - link_box_add() made a no-op: the run is painted and located, the click
#     lands on it, and nothing is under it as far as the hit test knows.
#   - the parsed href dropped on the floor in dom.c0: the anchor is still
#     styled as a link, because the stylesheet matches the tag rather than
#     the attribute, so the run is still found and still clicked.
# Both leave the first page on screen and fail check 3. The second is the
# reason check 1 cannot be "we found blue text, so the href survived".
set -u
cd "$(dirname "$0")"

./build.sh || exit 1

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
if [ ! -f moonshot.iso ]; then
  echo "FAIL: grub-mkrescue did not produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

sockfile=verify_utsikt_links.sock
rm -f serial.log "$sockfile" ulink_*.ppm
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

sleep 2

python3 - "$sockfile" <<'EOF'
import socket, sys, time

LINK_RGB = (0, 64, 192)      # default stylesheet: a { color: #0040c0 }

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.2)
sock.recv(65536)

def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    try:
        sock.recv(65536)
    except BlockingIOError:
        pass

def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "_": "shift-minus"}
    typ([keymap.get(c, c) for c in s])

def shot(name):
    send("screendump %s" % name, settle=0.9)

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace():
            pos += 1
        if data[pos:pos+1] == b"#":
            while data[pos:pos+1] != b"\n":
                pos += 1
            continue
        start = pos
        while not data[pos:pos+1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    w, h, _ = fields
    return w, h, data[pos:]

# The emulated mouse is relative. Park it at the origin by overshooting the
# screen in both axes, which klick clamps, then track absolute position.
pos = [512, 384]
def park():
    for _ in range(9):
        send("mouse_move -100 -100", settle=0.04)
    pos[0] = 0
    pos[1] = 0

def move_to(x, y):
    while pos[0] != x or pos[1] != y:
        dx = max(-100, min(100, x - pos[0]))
        dy = max(-100, min(100, y - pos[1]))
        send("mouse_move %d %d" % (dx, dy), settle=0.04)
        pos[0] += dx
        pos[1] += dy

# raket login gate: root, then an empty password.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)

# utsikt takes a tavla beside the shell. Focus it first, the way
# verify_utsikt.sh does, so Backspace later reaches the browser.
word("spawn3 utsikt.elf"); typ(["ret"]); time.sleep(4.5)
typ(["alt-tab"]); time.sleep(1.5)
shot("ulink_first.ppm")

# Locate the link by its colour. Every pixel of it belongs to one run, so
# the bounding box is the run and its centre is a point inside the word.
w, h, buf = read_ppm("ulink_first.ppm")
xs = []
ys = []
for y in range(h):
    row = y * w
    for x in range(w):
        off = (row + x) * 3
        if (buf[off], buf[off+1], buf[off+2]) == LINK_RGB:
            xs.append(x)
            ys.append(y)
if not xs:
    print("FAIL: no link-coloured pixels on the first page. Either the href")
    print("      never survived parsing, or the anchor was not styled as a")
    print("      link, and there is nothing to click.")
    raise SystemExit(1)

cx = (min(xs) + max(xs)) // 2
cy = (min(ys) + max(ys)) // 2
print("link run found: x %d..%d, y %d..%d, clicking (%d, %d)"
      % (min(xs), max(xs), min(ys), max(ys), cx, cy))

park()
move_to(cx, cy)
send("mouse_button 1", settle=0.35)
send("mouse_button 0", settle=0.35)
time.sleep(2.5)
shot("ulink_second.ppm")

# Back.
typ(["backspace"]); time.sleep(2.5)
shot("ulink_back.ppm")

sock.close()
EOF

sleep 1

python3 - <<'PY'
FIRST_BG  = (240, 239, 232)   # index.html: body { background: #f0efe8 }
SECOND_BG = (232, 224, 244)   # about.html: body { background: #e8e0f4 }
MIN_SHARE = 0.40              # a rendered page covers its whole viewport, so
                              # the page on screen measures far above this and
                              # the other one far below

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace():
            pos += 1
        if data[pos:pos+1] == b"#":
            while data[pos:pos+1] != b"\n":
                pos += 1
            continue
        start = pos
        while not data[pos:pos+1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    w, h, _ = fields
    return w, h, data[pos:]

# Measure inside the tavla only: it is the right half of the screen, and the
# shell beside it would otherwise dilute every fraction.
def shares(path):
    w, h, buf = read_ppm(path)
    x0 = w // 2
    first = second = total = 0
    for y in range(14, h - 14):
        row = y * w
        for x in range(x0, w):
            off = (row + x) * 3
            c = (buf[off], buf[off+1], buf[off+2])
            total += 1
            if c == FIRST_BG:
                first += 1
            elif c == SECOND_BG:
                second += 1
    if total == 0:
        return 0.0, 0.0
    return first / total, second / total

ok = True

f1, s1 = shares("ulink_first.ppm")
print("before the click:  index %.2f, about %.2f" % (f1, s1))
if f1 < MIN_SHARE:
    print("FAIL: the first page is not on screen to begin with")
    ok = False

f2, s2 = shares("ulink_second.ppm")
print("after the click:   index %.2f, about %.2f" % (f2, s2))
if s2 < MIN_SHARE:
    print("FAIL: clicking the link did not load the page it points at. The")
    print("      run was found and clicked, so either the rectangle recorded")
    print("      at paint time does not match where the words were painted,")
    print("      or the target never reached load_document.")
    ok = False
elif f2 >= MIN_SHARE:
    print("FAIL: both pages are on screen at once, which is a repaint bug")
    print("      rather than a navigation one")
    ok = False
else:
    print("PASS: the click followed the link -- a different file is rendered")

# Check 4 only means anything once check 3 has held. If the click never
# navigated, the first page is trivially still on screen and "came back"
# would report PASS for a browser that cannot follow a link at all. Gating
# it is the same rule the coverage check in verify_utsikt_resize.sh follows.
f3, s3 = shares("ulink_back.ppm")
print("after Backspace:   index %.2f, about %.2f" % (f3, s3))
if not ok:
    print("SKIP: nothing navigated, so coming back proves nothing")
elif f3 < MIN_SHARE or s3 >= MIN_SHARE:
    print("FAIL: Backspace did not come back to the page the link was on")
    ok = False
else:
    print("PASS: Backspace popped the history and reloaded the first page")

import re
log = open("serial.log", "rb").read().decode("utf-8", "replace")
panics = len(re.findall(r"PANIC", log))
faults = len(re.findall(r"double fault", log, re.I))
print("panics: %d, double faults: %d" % (panics, faults))
if panics or faults:
    ok = False

print()
if ok:
    print("PASS: utsikt follows links and comes back")
    raise SystemExit(0)
print("FAIL: utsikt does not follow links correctly")
raise SystemExit(1)
PY
