#!/usr/bin/env bash
#
# verify_utsikt.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that utsikt renders a document off the filesystem, and that what it
# renders is a LAYOUT rather than a picture.
#
# The difficulty with checking a renderer is that almost any bug still puts
# pixels on the screen. So every check below is one a broken engine fails:
#
#   1. The page background covers the window. If the CSS never reached the
#      body element, this is whatever was in the buffer.
#   2. A .note div paints a band of its own background colour, several
#      pixels tall and most of the content box wide. That colour appears in
#      exactly one rule, matched by a CLASS selector, and the band's width
#      is the block box -- so it proves the cascade, the class selector, the
#      block layout and the background painting in one measurement.
#   3. Dark text pixels sit INSIDE that band. Text is painted after the box
#      it sits on, so a background drawn in the wrong order erases it.
#   4. PageDown moves the band up by a whole window, and does not merely
#      change the picture. A renderer that repainted without re-flowing, or
#      that scrolled by blitting, fails this differently from one that does
#      not scroll at all.
#   5. Home puts it back exactly. Scrolling must not be destructive: the
#      screen after a scroll down and back has to be the screen before it,
#      pixel for pixel. This is the check that catches layout state leaking
#      between frames -- a pen position not reset, a line height carried
#      over, an alloc that grows on every render.
#
# The window is a tavla beside the shell tile, the way spawn3 leaves it.
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

sockfile=verify_utsikt.sock
rm -f serial.log "$sockfile" utsikt_*.ppm
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
def shot(name):
    send("screendump %s" % name, settle=0.8)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("spawn3 utsikt.elf"); typ(["ret"]); time.sleep(4.0)
# spawn3 leaves focus on the shell, so the scroll keys would go there.
# Focus FIRST and only then take the reference shot: alt+tab retints both
# windows' title strips, and check 5 compares whole frames.
typ(["alt-tab"]); time.sleep(1.5)
shot("utsikt_top.ppm")
# Four presses of Down, which utsikt defines as three character cells each.
# An exact expected distance is what separates "something moved" from "the
# document scrolled by the amount it was asked to".
typ(["down", "down", "down", "down"]); time.sleep(1.5)
shot("utsikt_down.ppm")
typ(["pgdn"]); time.sleep(1.5)
shot("utsikt_pgdn.ppm")
typ(["home"]); time.sleep(1.5)
shot("utsikt_home.ppm")
sock.close()
EOF2
sleep 1

python3 - <<'PY'
import sys

BODY_BG = (240, 239, 232)     # body { background: #f0efe8 }
NOTE_BG = (200, 224, 200)     # .note { background: #c8e0c8 }
CELL_H = 8                    # punkt's character cell, what utsikt scrolls by

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

def px(buf, w, x, y):
    off = ((y * w) + x) * 3
    return (buf[off], buf[off+1], buf[off+2])

# Everything is measured inside the tavla only. The shell tile beside it has
# a blinking cursor and the status bar counts seconds, so a whole-screen
# comparison reports those as differences -- it did, on the first run of
# this script, as 63 bytes that looked exactly like a renderer bug.
def region(w, h):
    return range(w // 2, w), range(14, h - 14)

def scan(path):
    w, h, buf = read_ppm(path)
    xs, ys = region(w, h)
    body = 0
    note_rows = {}
    for y in ys:
        for x in xs:
            c = px(buf, w, x, y)
            if c == BODY_BG:
                body += 1
            elif c == NOTE_BG:
                note_rows.setdefault(y, []).append(x)
    return w, h, buf, body, note_rows

def window_bytes(path):
    w, h, buf = read_ppm(path)
    xs, ys = region(w, h)
    out = bytearray()
    for y in ys:
        base = y * w * 3
        out += buf[base + xs.start * 3 : base + xs.stop * 3]
    return bytes(out)

ok = True

w, h, top_buf, body_px, note_rows = scan("utsikt_top.ppm")
print("screen %dx%d, measuring the tavla only" % (w, h))
print("body background pixels: %d" % body_px)
if body_px < 20000:
    print("FAIL: the page background barely covers anything -- the body rule "
          "did not reach the layout")
    ok = False

if not note_rows:
    print("FAIL: no .note band -- the class selector, the block box or the "
          "background painting is broken")
    ok = False
else:
    rows = sorted(note_rows)
    widest = max(len(v) for v in note_rows.values())
    print(".note band: rows %d..%d (%d rows), widest run %d px"
          % (rows[0], rows[-1], len(rows), widest))
    if len(rows) < 20:
        print("FAIL: the .note box is too short to be a laid-out block")
        ok = False
    if widest < 200:
        print("FAIL: the .note box is too narrow to be a block box")
        ok = False
    # Contiguous, every row of it. A filled box with gaps in it is not a
    # cosmetic problem, it is the engine writing somewhere other than where
    # the kernel reads: the composite buffer is allocated for the biggest
    # window the machine can give out but present() packs its rows at the
    # CURRENT window's width, and striding by the wrong one showed every
    # second row of the page with untouched buffer in between. The box was
    # still 60 rows and still 492 px wide, so only this check sees it.
    missing = [y for y in range(rows[0], rows[-1] + 1) if y not in note_rows]
    if missing:
        print("FAIL: the .note box has %d unpainted rows inside it (first at "
              "%d) -- the composite buffer and present() disagree about the "
              "row stride" % (len(missing), missing[0]))
        ok = False
    xs = note_rows[rows[len(rows)//2]]
    x0, x1 = min(xs), max(xs)
    dark = 0
    for y in rows:
        for x in range(x0, x1 + 1):
            r, g, b = px(top_buf, w, x, y)
            if r < 120 and g < 120 and b < 120:
                dark += 1
    print("dark text pixels inside the .note box: %d" % dark)
    if dark < 100:
        print("FAIL: no text inside the .note box -- the background was "
              "painted over its own contents")
        ok = False

_, _, down_buf, _, note_rows_down = scan("utsikt_down.ppm")
if not note_rows or not note_rows_down:
    print("FAIL: the .note band is missing after scrolling down")
    ok = False
else:
    moved = sorted(note_rows)[0] - sorted(note_rows_down)[0]
    want = 4 * 3 * CELL_H
    print(".note band moved up %d px on four Down presses (expected %d)"
          % (moved, want))
    if moved != want:
        print("FAIL: the document did not scroll by the amount it was asked to")
        ok = False

if window_bytes("utsikt_pgdn.ppm") == window_bytes("utsikt_down.ppm"):
    print("FAIL: PageDown changed nothing")
    ok = False
else:
    print("PageDown moved the document further")

if window_bytes("utsikt_home.ppm") == window_bytes("utsikt_top.ppm"):
    print("Home reproduced the first frame exactly")
else:
    a = window_bytes("utsikt_home.ppm")
    b = window_bytes("utsikt_top.ppm")
    diff = sum(1 for i in range(min(len(a), len(b))) if a[i] != b[i])
    print("FAIL: Home did not reproduce the first frame (%d bytes differ) -- "
          "layout state is leaking between renders" % diff)
    ok = False

sys.exit(0 if ok else 1)
PY
rc=$?

echo
echo "--- what the kernel saw ---"
grep -E 'utsikt|spawn|elf_load|page fault|PANIC' serial.log | tail -20 || true

if [ "$rc" -eq 0 ]; then
  echo
  echo "PASS: utsikt rendered /index.html, and its layout scrolls and comes back"
  exit 0
fi
echo
echo "FAIL: see above"
exit 1
