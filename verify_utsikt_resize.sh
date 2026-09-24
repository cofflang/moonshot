#!/usr/bin/env bash
#
# verify_utsikt_resize.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that utsikt RE-WRAPS its text when its window is resized under it,
# rather than keeping the line breaks it computed at the old width.
#
# verify_resize.sh already proves a graphical program survives a resize --
# that its frame still fills the tile and is not read at the wrong pitch.
# That is a different claim. A program can repaint a resized window perfectly
# and still be showing a layout computed for the old geometry; for a browser
# that is the whole difference between a layout engine and a picture.
#
# utsikt's main loop re-reads win_info() every frame and sets `dirty` when
# the geometry moved, which re-runs render_page() at the new view_w. This
# script is the evidence for that paragraph in the source.
#
# The measurement is the .note div's painted band, for the same reason
# verify_utsikt.sh uses it: its background colour appears in exactly one CSS
# rule, so every pixel of it is attributable. The band is a block box holding
# a fixed amount of text, so its two dimensions answer two different
# questions:
#
#   1. The band gets WIDER. That only proves the box was re-laid out to the
#      new content width -- a renderer that re-flowed boxes but not text
#      would pass this.
#   2. The band gets SHORTER. This is the one that proves re-wrap: the same
#      sentence at double the width needs fewer lines, so the box that holds
#      it loses height.
#
# Check 2 is NOT sufficient on its own, and the first version of this script
# was wrong to think it was. "Nothing but re-wrapping makes a block box shrink
# vertically while growing horizontally" is false: a PITCH MISMATCH does
# exactly that. If the buffer stays strided at the old width while present()
# reads it at the new one, each output row swallows two source rows, so the
# page appears at double width and half height -- 1004x31 against a true
# re-wrap's 1004x38. Measured, not reasoned: a deliberately pinned view_w
# produced precisely that and check 2 reported PASS.
#
# So check 0 runs first and the band checks only mean anything after it:
#
#   0. COVERAGE. The page background must still reach the BOTTOM of the
#      widened window. Under the pitch artifact the content is squeezed into
#      the top half and the bottom is untouched buffer, so this is the check
#      that separates "re-laid out" from "read at the wrong stride". It is
#      the same assertion verify_resize.sh settled on, for the same reason.
#
# Validated by breaking it, twice, because the first break did not exercise
# every check:
#   - Remove the `ww != last_w || wh != last_h` test in utsikt.c0's main loop:
#     the program never re-renders, never presents, and the widened tile keeps
#     kakel's reflow clear. The band vanishes; checks 0 and 2 fail.
#   - Pin the layout width (`view_w`) to the first value seen while still
#     repainting: the pitch artifact above. Check 0 fails; checks 1 and 2 both
#     report PASS, which is exactly why check 0 has to gate them.
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

sockfile=verify_utsikt_resize.sock
rm -f serial.log "$sockfile" uresize_*.ppm
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

sleep 2

python3 - "$sockfile" <<'EOF'
import socket, sys, time

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

# raket login gate: root, then an empty password.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)

# utsikt takes a tavla beside the shell tile: the right half of the screen.
word("spawn3 utsikt.elf"); typ(["ret"]); time.sleep(4.5)
shot("uresize_half.ppm")

# spawn3 leaves focus on the shell, so `close` goes to the shell window and
# closes IT -- leaving the tavla as the only tile, at full width.
word("close"); typ(["ret"]); time.sleep(3.5)
shot("uresize_full.ppm")

sock.close()
EOF

sleep 1

python3 - <<'PY'
BODY_BG = (240, 239, 232)     # body { background: #f0efe8 }
NOTE_BG = (200, 224, 200)     # .note { background: #c8e0c8 }
MIN_BAND_PX = 20              # a row inside the band has far more than this
BOTTOM_ROWS = 40              # how deep to sample for the coverage check
MIN_COVERAGE = 0.50           # a true re-wrap measures ~1.0 here, the pitch
                              # artifact ~0.0; the threshold is nowhere near
                              # either, deliberately

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

# Measure the band inside the tavla only. x0 differs between the two shots
# because the window itself moved: half-width tavla on the right, full-width
# tavla spanning the screen. y stays clear of the title strip and status bar.
def band(path, x0):
    w, h, buf = read_ppm(path)
    rows = {}
    for y in range(14, h - 14):
        xs = [x for x in range(x0, w) if px(buf, w, x, y) == NOTE_BG]
        if len(xs) >= MIN_BAND_PX:
            rows[y] = (min(xs), max(xs))
    if not rows:
        return w, h, 0, 0
    height = len(rows)
    width = max(hi - lo + 1 for lo, hi in rows.values())
    return w, h, width, height

# Fraction of the bottom of the tavla that is still the page's own
# background. flow.c0 fills the whole viewport with page_bg before painting,
# so on a correctly re-laid-out frame this is essentially 1.0. When present()
# reads the buffer at the wrong stride the page is squeezed into the top half
# and this collapses toward 0.
def bottom_coverage(path, x0):
    w, h, buf = read_ppm(path)
    y1 = h - 14
    y0 = y1 - BOTTOM_ROWS
    hits = 0
    total = 0
    for y in range(y0, y1):
        for x in range(x0, w):
            total += 1
            if px(buf, w, x, y) == BODY_BG:
                hits += 1
    return hits / total if total else 0.0

ok = True

screen_w, _, _ = read_ppm("uresize_half.ppm")
w, h, nw, nh = band("uresize_half.ppm", screen_w // 2)
print("half-width tavla:  .note band %d px wide, %d px tall" % (nw, nh))

w2, h2, fw, fh = band("uresize_full.ppm", 0)
print("full-width tavla:  .note band %d px wide, %d px tall" % (fw, fh))

if nw == 0 or nh == 0:
    print("FAIL: no .note band before the resize -- the page never rendered,")
    print("      so nothing below measures a re-wrap")
    ok = False

if fw == 0 or fh == 0:
    print("FAIL: no .note band after the resize -- utsikt did not repaint the")
    print("      widened window at all, so the tile still holds kakel's clear")
    ok = False

if ok:
    # 0. Coverage, FIRST: the band measurements below are only meaningful
    # once we know the frame is being read at the right stride.
    cov = bottom_coverage("uresize_full.ppm", 0)
    print("bottom %d rows of the widened tavla: %.2f page background"
          % (BOTTOM_ROWS, cov))
    if cov < MIN_COVERAGE:
        print("FAIL: the page no longer reaches the bottom of the window. The")
        print("      frame is being read at the wrong pitch, which squeezes it")
        print("      into the top half -- and that alone would make the band")
        print("      below look wider and shorter. The band checks are")
        print("      meaningless in this state.")
        ok = False

if ok:
    # 1. The box was re-laid out to the new content width.
    if fw > nw * 3 // 2:
        print("PASS: the band grew with the window (%d -> %d px wide)" % (nw, fw))
    else:
        print("FAIL: the band did not widen (%d -> %d px) -- the block box "
              "kept its old content width" % (nw, fw))
        ok = False

    # 2. The text inside it re-wrapped. This is the check that matters.
    if fh < nh:
        print("PASS: the band SHRANK vertically (%d -> %d px tall) -- the same "
              "text needed fewer lines at the greater width, which is a "
              "re-wrap" % (nh, fh))
    else:
        print("FAIL: the band kept its height (%d -> %d px tall). The box was "
              "resized but the text inside it was not re-wrapped -- the line "
              "breaks are still the ones computed for the old width." % (nh, fh))
        ok = False

import re
log = open("serial.log", "rb").read().decode("utf-8", "replace")
panics = len(re.findall(r"PANIC", log))
faults = len(re.findall(r"double fault", log, re.I))
print("panics: %d, double faults: %d" % (panics, faults))
if panics or faults:
    ok = False

print()
if ok:
    print("PASS: utsikt re-wraps its text when its window is resized under it")
    raise SystemExit(0)
print("FAIL: utsikt did not re-wrap on resize")
raise SystemExit(1)
PY
