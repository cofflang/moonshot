#!/usr/bin/env bash
#
# verify_utsikt_table.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that utsikt lays out a <table> as a grid, rather than running its
# cells together as inline text.
#
# /about.html carries a five-row, two-column table (a header row and four
# data rows). The engine draws the grid in a colour used nowhere else, so
# the structure can be read straight off the screen:
#
#   1. Six horizontal rules. Five rows have five tops and one bottom. Four
#      would mean a row was lost, seven would mean one was invented.
#   2. Evenly spaced. Every row on this page holds one short line, so every
#      row should be the same height. An uneven pitch means row heights came
#      from something other than the tallest cell in each row.
#   3. Three vertical rules, for two columns. Two would mean the columns
#      were never separated; four would mean a column was invented from a
#      row that has more cells than the others, which none here does.
#
# Reading the table from the grid rather than from its text is deliberate.
# The text would prove the words are on screen somewhere, which they were
# before tables existed too, when they ran together into one paragraph. The
# grid is the thing that is new.
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

sockfile=verify_utsikt_table.sock
rm -f serial.log "$sockfile" utable_*.ppm
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
# The table is on the second page, so focus the browser and follow the link.
typ(["alt-tab"]); time.sleep(1.5)
send("screendump utable_first.ppm", settle=0.9)
w, h, buf = read_ppm("utable_first.ppm")
xs, ys = [], []
for y in range(h):
    row = y * w
    for x in range(w):
        off = (row + x) * 3
        if (buf[off], buf[off+1], buf[off+2]) == LINK_RGB:
            xs.append(x); ys.append(y)
if not xs:
    print("FAIL: no link on the first page, so about.html cannot be reached")
    raise SystemExit(1)
park()
move_to((min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2)
send("mouse_button 1", settle=0.35)
send("mouse_button 0", settle=0.35)
time.sleep(2.5)
# Park the pointer off the table so its glyph cannot be counted as grid.
park()
time.sleep(1.0)
send("screendump utable_page.ppm", settle=1.0)
sock.close()
EOF2

sleep 1

python3 - <<'PY'
import sys
GRID = (0x90, 0x98, 0xa0)
WANT_RULES = 6      # five rows: five tops and one bottom
WANT_COLS  = 3      # two columns: three verticals

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

w, h, buf = read_ppm("utable_page.ppm")
x0 = w // 2
per_row = {}
per_col = {}
for y in range(h):
    row = y * w
    for x in range(x0, w):
        off = (row + x) * 3
        if (buf[off], buf[off+1], buf[off+2]) == GRID:
            per_row[y] = per_row.get(y, 0) + 1
            per_col[x] = per_col.get(x, 0) + 1

if not per_row:
    print("FAIL: no grid pixels at all. The <table> did not lay out as a")
    print("      table -- its cells most likely ran together as text.")
    raise SystemExit(1)

# A horizontal rule spans the table; a vertical one contributes a single
# pixel per row. The two are separated by how much of the line they cover.
width = max(per_row.values())
rules = sorted(y for y in per_row if per_row[y] > width // 2)
cols = sorted(x for x in per_col if per_col[x] > 10)
print("horizontal rules at rows: %s" % rules)
print("vertical rules at columns: %s" % cols)

ok = True
if len(rules) != WANT_RULES:
    print("FAIL: %d horizontal rules, expected %d for five rows."
          % (len(rules), WANT_RULES))
    ok = False
else:
    pitch = [rules[i+1] - rules[i] for i in range(len(rules) - 1)]
    print("row pitch: %s" % pitch)
    if max(pitch) - min(pitch) > 1:
        print("FAIL: the rows are not evenly spaced, so row height is not")
        print("      coming from the tallest cell in each row.")
        ok = False

if len(cols) != WANT_COLS:
    print("FAIL: %d vertical rules, expected %d for two columns."
          % (len(cols), WANT_COLS))
    ok = False
else:
    cw = [cols[i+1] - cols[i] for i in range(len(cols) - 1)]
    print("column widths: %s" % cw)
    if max(cw) - min(cw) > 1:
        print("FAIL: the two columns are not equal width, which is what this")
        print("      engine lays tables out as.")
        ok = False

sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: a table lays out as a grid of five rows and two equal columns"
  exit 0
fi
echo "FAIL: see above"
exit 1
