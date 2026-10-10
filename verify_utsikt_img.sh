#!/usr/bin/env bash
#
# verify_utsikt_img.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# <img> in utsikt. about.html shows moon.spr, a 48x48 sprite the kernel
# draws at boot (jakel_seed_moon). This follows the link to about.html,
# scrolls to the end and checks the picture.
#
#   1. Every pixel of it is there. The moon's two colours are counted and
#      compared with the counts the same geometry produces, exactly, so a
#      clipped, offset or half-drawn image fails.
#   2. Transparency works. The corners of the 48x48 square are outside the
#      disc, all-zero pixels in the file, and must show the page background
#      through them rather than black.
#   3. It sits in the line like a word, so the text after it continues on the
#      same line, level with the image's bottom edge.
#   4. lager refused no dealloc, so the image's memory belongs to the page.
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

sockfile=verify_utsikt_img.sock
rm -f serial.log "$sockfile" uimg_*.ppm
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

# raket login gate, root, then an empty password.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("spawn3 utsikt.elf"); typ(["ret"]); time.sleep(4.5)
typ(["alt-tab"]); time.sleep(1.5)
shot("uimg_first.ppm")

# Follow the link to about.html, found by its colour as in
# verify_utsikt_links.sh.
w, h, buf = read_ppm("uimg_first.ppm")
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
    print("FAIL: no link to about.html found on the first page")
    raise SystemExit(1)
park()
move_to((min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2)
send("mouse_button 1", settle=0.35)
send("mouse_button 0", settle=0.35)
time.sleep(2.5)
typ(["end"]); time.sleep(1.5)
shot("uimg_end.ppm")
sock.close()
EOF

sleep 1

python3 - <<'PY'
import re

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

PAGE_BG = (0xE8, 0xE0, 0xF4)   # about.html: body { background: #e8e0f4 }
TEXT = (0x20, 0x20, 0x20)      # about.html: body { color: #202020 }
LIGHT = (0xF0, 0xE6, 0xC8)     # jakel_seed_moon's MOON_LIGHT
CRATER = (0xB4, 0xA8, 0x8C)    # and MOON_CRATER

# The same geometry jakel_seed_moon draws, counted here independently.
def inside(x, y, cx, cy, r):
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r
want_light = want_crater = 0
for y in range(48):
    for x in range(48):
        if inside(x, y, 24, 24, 22):
            if inside(x, y, 16, 18, 5) or inside(x, y, 31, 29, 7) or inside(x, y, 20, 34, 3):
                want_crater += 1
            else:
                want_light += 1

w, h, buf = read_ppm("uimg_end.ppm")
def px(x, y):
    o = (y * w + x) * 3
    return (buf[o], buf[o+1], buf[o+2])

got_light = got_crater = 0
xs = []
ys = []
for y in range(h):
    for x in range(w // 2, w):
        c = px(x, y)
        if c == LIGHT:
            got_light += 1
        elif c == CRATER:
            got_crater += 1
        else:
            continue
        xs.append(x)
        ys.append(y)

ok = True
print("moon pixels: light %d (want %d), crater %d (want %d)"
      % (got_light, want_light, got_crater, want_crater))
if got_light != want_light or got_crater != want_crater:
    print("FAIL: the image is not drawn whole")
    ok = False

if xs:
    # The disc spans 2..46 of the 48x48 square, so the square's corner is
    # two pixels up and left of the disc's bounding box.
    ox = min(xs) - 2
    oy = min(ys) - 2
    corners = [px(ox, oy), px(ox + 47, oy), px(ox, oy + 47), px(ox + 47, oy + 47)]
    print("image at (%d, %d), corners %s" % (ox, oy, corners))
    if any(c != PAGE_BG for c in corners):
        print("FAIL: transparent pixels do not show the page behind them")
        ok = False
    # The text after the image, on the same line, whose glyphs sit on the
    # image's bottom edge, in the 8 rows above it, right of the image.
    bottom = oy + 47
    beside = sum(1 for y in range(bottom - 8, bottom + 1)
                 for x in range(ox + 48, min(w, ox + 48 + 120)) if px(x, y) == TEXT)
    print("text pixels on the image's line, after it: %d" % beside)
    if beside < 20:
        print("FAIL: the text after the image did not continue on its line")
        ok = False
else:
    print("FAIL: no moon on screen at all")
    ok = False

log = open("serial.log", "rb").read().decode("utf-8", "replace")
refused = re.findall(r"\[lager\] dealloc: not a live block.*", log)
if refused:
    print("FAIL: lager refused %d dealloc(s)" % len(refused))
    ok = False
if re.search(r"PANIC|double fault", log, re.I):
    print("FAIL: panic or double fault")
    ok = False

print()
if ok:
    print("PASS: utsikt draws an <img> whole, transparent and in line")
    raise SystemExit(0)
print("FAIL: <img> is not right")
raise SystemExit(1)
PY
