#!/usr/bin/env bash
#
# verify_utsikt_margins.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that utsikt COLLAPSES adjacent vertical margins instead of adding
# them, which is what every other browser does and what utsikt at first did
# not do.
#
# The measurement is a gap between two things that are both visible as
# pixels, on the page the browser already opens. /index.html has
#
#     .note { background: #c8e0c8; margin: 8px; padding: 8px; }
#
# immediately followed by an <h2>, which the same page styles
#
#     h2 { color: #204020; margin: 10px; }
#
# The note has a background, so the bottom edge of its box is a real row of
# known-coloured pixels. The h2 has a colour of its own, used nowhere else,
# so its first glyph row is findable too. Between them lies the note's 8px
# bottom margin meeting the h2's 10px top margin, and nothing else.
#
#   collapsed:   max(8, 10) = 10
#   added:       8 + 10     = 18
#
# Those two numbers are far enough apart that the check does not need to be
# clever, and the measured value was 18 before the change and 10 after it,
# so this test has been seen to produce both answers rather than only the
# one it wants.
#
# It deliberately measures a gap rather than the document's total height. A
# height would also shrink, but by an amount that depends on every margin on
# the page, so it would fail for any change to the page and say nothing
# about why.
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

sockfile=verify_utsikt_marg.sock
rm -f serial.log "$sockfile" umarg_*.ppm
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
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("spawn3 utsikt.elf"); typ(["ret"]); time.sleep(4.5)
send("screendump umarg_page.ppm", settle=1.0)
sock.close()
EOF2

sleep 1

python3 - <<'PY'
import sys
NOTE_BG = (0xc8, 0xe0, 0xc8)
H2_FG   = (0x20, 0x40, 0x20)
COLLAPSED = 10      # max(8, 10)
ADDED     = 18      # 8 + 10
SLACK     = 2

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

def rows_with(buf, w, h, x0, colour):
    out = []
    for y in range(h):
        row = y * w
        for x in range(x0, w):
            off = (row + x) * 3
            if (buf[off], buf[off+1], buf[off+2]) == colour:
                out.append(y)
                break
    return out

w, h, buf = read_ppm("umarg_page.ppm")
x0 = w // 2                      # the browser is the right-hand tile
note = rows_with(buf, w, h, x0, NOTE_BG)
if not note:
    print("FAIL: the .note box is not on screen, so there is no gap to measure")
    raise SystemExit(1)
note_bottom = max(note)
h2 = [y for y in rows_with(buf, w, h, x0, H2_FG) if y > note_bottom]
if not h2:
    print("FAIL: no <h2> below the note, so there is no gap to measure")
    raise SystemExit(1)

gap = h2[0] - note_bottom - 1
print("note box ends at row %d, the h2 below it starts at row %d" % (note_bottom, h2[0]))
print("gap = %d px   (collapsed would be %d, added would be %d)" % (gap, COLLAPSED, ADDED))

if abs(gap - COLLAPSED) <= SLACK:
    sys.exit(0)
if abs(gap - ADDED) <= SLACK:
    print("FAIL: the margins ADDED. An 8px bottom margin met a 10px top")
    print("      margin and produced 18px of space instead of 10.")
    sys.exit(1)
print("FAIL: the gap is neither the collapsed nor the added value, so the")
print("      page changed under this check and the numbers above need")
print("      re-deriving from the stylesheet before this means anything.")
sys.exit(1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: adjacent vertical margins collapse to the larger of the two"
  exit 0
fi
echo "FAIL: see above"
exit 1
