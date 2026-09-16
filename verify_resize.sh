#!/usr/bin/env bash
#
# verify_resize.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves a graphical ring-3 program survives its window being RESIZED under
# it -- the thing SYS_WIN_MAX and view_poll_resize exist for.
#
# A kakel tile is not a fixed size. Any reflow (`split`, `close`, another
# `spawn3`) hands every visible window new geometry, and nothing tells the
# program. Before this worked, a running Infecteria whose tile widened kept
# presenting a buffer written at the OLD row pitch, and SYS_PRESENT read it at
# the NEW one. At double the width that means each screen row swallowed two
# source rows, so the frame came out interleaved and vertically squashed into
# the top half of the tile -- and past the last row the buffer had, it read
# clean off the mapped part of the task's heap: an unmapped read in ring 0,
# inside a syscall.
#
# Checked in pixels rather than in source, for the reason every other verify
# script here gives: the wrong-pitch frame looked entirely plausible in the
# draw code, and only a screendump showed it stopping halfway down the window.
#
# The check that does the work is COVERAGE, deliberately. An earlier draft
# also asserted the two halves of the window were not pixel-identical, on the
# theory that a doubled pitch duplicates the frame side by side. Running this
# script against a deliberately un-fixed kernel showed that theory was wrong
# -- reading at double pitch interleaves rows, it does not mirror them -- so
# that check could never have fired and has been removed rather than kept as
# reassurance. Coverage was the assertion that actually caught it.
#
# Checks, in one boot:
#   1. GROW. spawn3 Infecteria into half the screen, then close the shell
#      window so the tavla becomes the only one and doubles in width. The
#      bottom of the window must then be painted with the game's own
#      background, not left as kakel's reflow clear. Verified to FAIL on a
#      kernel with the fix backed out (bottom row: 0.00 game background
#      against 1.00 with it), which is the only evidence that a regression
#      test is worth having.
#   2. The un-resized baseline: while the tile was still half-width, the game
#      must already have been filling it top to bottom, so a pass on 1 cannot
#      be explained by the game simply painting everything everywhere.

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

sockfile=verify_resize.sock
rm -f serial.log "$sockfile" resize_*.ppm
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

def send(cmd, settle=0.05):
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
    keymap = {".": "dot", " ": "spc", "-": "minus"}
    typ([keymap.get(c, c) for c in s])

def shot(name):
    send("screendump %s" % name, settle=0.8)

# raket login gate: root, then an empty password.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.0)

# 1: spawn the game into half the screen, let it render a few frames, then
# close the shell window beside it so its tile doubles in width.
word("spawn3 infecteria.elf"); typ(["ret"])
time.sleep(4.0)
shot("resize_half.ppm")
word("close"); typ(["ret"])
time.sleep(3.0)
shot("resize_grown.ppm")

sock.close()
EOF

sleep 1

python3 - <<'EOF'
FONT_H = 8
KAKEL_LOG_ROWS = 1
TITLE_ROWS = 1

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
    off = (y * w + x) * 3
    return (buf[off], buf[off+1], buf[off+2])

def row(buf, w, y, x0, x1):
    return [px(buf, w, x, y) for x in range(x0, x1)]

ok = True

w, h, grown = read_ppm("resize_grown.ppm")
# The tavla is now the only window: full width, from below its title strip
# down to the status bar.
top = TITLE_ROWS * FONT_H
bot = h - KAKEL_LOG_ROWS * FONT_H
print("grown tavla client area: %dx%d (rows %d..%d)" % (w, bot - top, top, bot))

# 1a. The frame has content at all. Everything below compares against the
# game's background colour, and an all-background frame would satisfy those
# comparisons no matter how broken the pitch was -- so establish first that
# the game actually drew something.
distinct = set()
for y in range(top, bot, 16):
    distinct.update(row(grown, w, y, 0, w))
    if len(distinct) > 3:
        break
print("frame content: %d distinct colours in the client area" % len(distinct))
if len(distinct) < 2:
    print("FAIL: the game's frame is a flat fill -- nothing was drawn, so the")
    print("      coverage checks below would pass vacuously")
    ok = False

# 1b. The game paints the whole height. Infecteria's own background is
# COL_BG = 0x101820, which reaches the framebuffer as B=0x20 G=0x18 R=0x10;
# a screendump PPM is RGB, so it reads back as (0x10, 0x18, 0x20).
COL_BG = (0x10, 0x18, 0x20)

def game_fraction(buf, w, y, x0, x1):
    r = row(buf, w, y, x0, x1)
    return sum(1 for p in r if p == COL_BG) / float(len(r))

near_bottom = bot - FONT_H * 2
upper = top + (bot - top) // 4
f_up = game_fraction(grown, w, upper, 8, w - 8)
f_lo = game_fraction(grown, w, near_bottom, 8, w - 8)
print("game background coverage: row %d = %.2f, row %d = %.2f"
      % (upper, f_up, near_bottom, f_lo))
if f_lo < 0.5:
    print("FAIL: the bottom of the enlarged tile is not the game's background --")
    print("      the frame is being cut off partway down instead of adapting")
    ok = False
if f_up < 0.5:
    print("FAIL: the game is not painting its enlarged tile at all")
    ok = False

# 2. The un-resized baseline, from the same boot's first screendump: while the
# tile was still half-width, the game must already have been filling it top to
# bottom. Without this, check 1 could be satisfied by a game that paints
# everything everywhere regardless of geometry.
w2, h2, half_shot = read_ppm("resize_half.ppm")
hb = h2 - KAKEL_LOG_ROWS * FONT_H
f_half_lo = game_fraction(half_shot, w2, hb - FONT_H * 2, w2 // 2 + 8, w2 - 8)
print("half-width tile, near bottom: %.2f game background" % f_half_lo)
if f_half_lo < 0.5:
    print("FAIL: the game does not fill its tile even before any resize")
    ok = False

if ok:
    print("PASS: a running graphical program survives its window being resized —")
    print("      its tile doubled in width mid-game and it repainted the whole of")
    print("      the new geometry, via SYS_WIN_MAX + a per-frame win_info() poll")
else:
    print("FAIL: resize handling is broken (see above)")
    raise SystemExit(1)
EOF
