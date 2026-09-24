#!/usr/bin/env bash
#
# verify_utsikt_address.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that utsikt's address line exists, says something, and says a
# DIFFERENT something once a link has been followed.
#
# The strip is drawn along the bottom of the browser's window in its own two
# colours, which appear nowhere else on the page, so it can be found by
# colour rather than by arithmetic on the window geometry.
#
#   1. The strip is there. Its background colour covers a band at the bottom
#      of the tavla.
#   2. There is text in it. A blank strip would satisfy check 1 perfectly
#      well and tell the reader nothing.
#   3. The text CHANGES when the page does. The same strip is captured
#      before and after following the link to about.html and the two must
#      not be identical. This is the check that makes it an ADDRESS line
#      rather than a decorative bar -- a hardcoded label would pass 1 and 2
#      and fail here.
#
# The comparison in check 3 is over the strip's pixels, not over a count of
# them, because "index.html" and "about.html" are the same length and a
# count could coincide.
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

sockfile=verify_utsikt_addr.sock
rm -f serial.log "$sockfile" uaddr_*.ppm
[ -f disk.img ] || dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'EOF2'
import socket, sys, time
LINK_RGB = (0, 64, 192)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.2)
sock.recv(65536)
def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    sock.recv(65536)
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

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("spawn3 utsikt.elf"); typ(["ret"]); time.sleep(4.5)
# Focus the browser, the way the links check does. The first click on an
# unfocused window only focuses it now, so a click meant to follow a link
# has to land on a window that already has focus.
typ(["alt-tab"]); time.sleep(1.5)
shot("uaddr_first.ppm")

w, h, buf = read_ppm("uaddr_first.ppm")
xs, ys = [], []
for y in range(h):
    row = y * w
    for x in range(w):
        off = (row + x) * 3
        if (buf[off], buf[off+1], buf[off+2]) == LINK_RGB:
            xs.append(x); ys.append(y)
if not xs:
    print("FAIL: no link on the first page, so there is nothing to follow")
    raise SystemExit(1)
cx = (min(xs) + max(xs)) // 2
cy = (min(ys) + max(ys)) // 2

park()
move_to(cx, cy)
send("mouse_button 1", settle=0.35)
send("mouse_button 0", settle=0.35)
time.sleep(2.5)
# Park the pointer off the strip so the pointer glyph cannot be what differs
# between the two captures.
park()
time.sleep(1.0)
shot("uaddr_second.ppm")
sock.close()
EOF2

sleep 1

python3 - <<'PY'
import sys
BAR_BG = (0x28, 0x28, 0x28)
BAR_FG = (0xd0, 0xd0, 0xc8)

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

def strip(path):
    """Every bar-coloured pixel in the right half, as a set of positions."""
    w, h, buf = read_ppm(path)
    x0 = w // 2
    bg, fg = set(), set()
    for y in range(h):
        row = y * w
        for x in range(x0, w):
            off = (row + x) * 3
            c = (buf[off], buf[off+1], buf[off+2])
            if c == BAR_BG:
                bg.add((x, y))
            elif c == BAR_FG:
                fg.add((x, y))
    return bg, fg

bg1, fg1 = strip("uaddr_first.ppm")
bg2, fg2 = strip("uaddr_second.ppm")
print("first page:  %d strip pixels, %d text pixels" % (len(bg1), len(fg1)))
print("second page: %d strip pixels, %d text pixels" % (len(bg2), len(fg2)))

ok = True
# A strip one line tall across a half-screen-wide tavla is thousands of
# pixels; anything in the hundreds is already unambiguous.
if len(bg1) < 500 or len(bg2) < 500:
    print("FAIL: no address strip along the bottom of the window.")
    ok = False
# "/index.html" is eleven glyphs, each a few dozen lit pixels.
if len(fg1) < 40 or len(fg2) < 40:
    print("FAIL: the strip is blank. It is there, but it says nothing.")
    ok = False
if ok and fg1 == fg2:
    print("FAIL: the strip reads the same on both pages, so it is not")
    print("      showing which file is open -- following a link to")
    print("      about.html left it unchanged.")
    ok = False
elif ok:
    d = len(fg1 ^ fg2)
    print("text pixels that differ between the two pages: %d" % d)
sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: the address line shows the open file and follows navigation"
  exit 0
fi
echo "FAIL: see above"
exit 1
