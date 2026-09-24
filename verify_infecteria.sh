#!/usr/bin/env bash
#
# verify_infecteria.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Infecteria's first test. The game had none at all until its sprites landed,
# which meant the renderer could be rewritten with nothing but a screenshot
# and an opinion to say whether it still worked.
#
# What it checks, and why each one is a thing that can actually break:
#
#   1. The player is drawn, in its own exact colours. The sprites are drawn
#      by code at startup (infecteria_art.c0) rather than loaded from a byte
#      array, so "the drawing code ran and produced something" is a claim
#      worth checking rather than assuming.
#   2. Cells are drawn in the CLEAN tint, and no cell is infected yet. Cells
#      go through view_sprite_tint, a different path from the player's flat
#      view_sprite, and the tint is what carries the game state.
#   3. Standing in a cell infects it, and the tint changes to match. This is
#      the core mechanic and the whole point of the tint path: one grey
#      sprite has to be able to read as clean and as infected.
#
# The colours below are computed, not sampled. A cell's membrane is drawn at
# full brightness and blended half and half with the background, so its pixel
# is the average of the tint and COL_BG -- which is a number this script can
# work out from the three constants in infecteria.c0 and would notice if any
# of them moved.
#
# The first cell is placed deliberately just below the player's start (see
# infecteria.c0), so this can walk onto it rather than search for one.
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

sockfile=verify_infecteria.sock
rm -f serial.log "$sockfile" infect_*.ppm
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
    keymap = {".": "dot", " ": "spc", "-": "minus"}
    typ([keymap.get(c, c) for c in s])
def shot(name):
    send("screendump %s" % name, settle=0.8)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("spawn3 infecteria.elf"); typ(["ret"]); time.sleep(4.0)
# spawn3 leaves focus on the shell, so the arrow keys would drive the shell.
typ(["alt-tab"]); time.sleep(1.5)
shot("infect_clean.ppm")

# Walk onto the cell below the start. QEMU's sendkey takes a hold time in
# milliseconds, which is the only way to give the game a HELD key: it tracks
# make and break, and a default 100ms tap barely moves the player at all.
send("sendkey down 1200", settle=1.8)
# Then stand still. Infection only runs while the player's centre is inside
# the cell, and drifting out is exactly what stops it.
time.sleep(3.0)
shot("infect_dirty.ppm")
sock.close()
EOF2
sleep 1

python3 - <<'PY'
import sys

# infecteria.c0's constants, and what they become on screen.
COL_BG      = (0x10, 0x18, 0x20)
COL_CELL    = (0x60, 0x80, 0xC0)
COL_INFECT  = (0xC0, 0x60, 0x40)
PLAYER_BODY = (0x40, 0xFF, 0x80)
PLAYER_RIM  = (0x1E, 0x8C, 0x4A)

def blend(a, b):
    """view_sprite_tint with blend=1: the average of the two, per channel."""
    return tuple((x + y) // 2 for x, y in zip(a, b))

CLEAN_MEMBRANE = blend(COL_CELL, COL_BG)
DIRTY_MEMBRANE = blend(COL_INFECT, COL_BG)

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

def count(path, colours):
    w, h, buf = read_ppm(path)
    tally = {c: 0 for c in colours}
    for y in range(h):
        row = y * w
        for x in range(w):
            o = (row + x) * 3
            c = (buf[o], buf[o+1], buf[o+2])
            if c in tally:
                tally[c] += 1
    return tally

ok = True
wanted = [PLAYER_BODY, PLAYER_RIM, CLEAN_MEMBRANE, DIRTY_MEMBRANE]
print("clean cell membrane on screen should be RGB %s, infected %s"
      % (CLEAN_MEMBRANE, DIRTY_MEMBRANE))

clean = count("infect_clean.ppm", wanted)
print("before: player body %d, player rim %d, clean membrane %d, infected %d"
      % (clean[PLAYER_BODY], clean[PLAYER_RIM],
         clean[CLEAN_MEMBRANE], clean[DIRTY_MEMBRANE]))

if clean[PLAYER_BODY] < 30 or clean[PLAYER_RIM] < 10:
    print("FAIL: the player sprite is not on screen -- the art was not drawn, "
          "or view_sprite is not drawing it")
    ok = False
if clean[CLEAN_MEMBRANE] < 100:
    print("FAIL: no cell membranes in the clean tint -- view_sprite_tint is "
          "not producing the colour the constants say it should")
    ok = False
if clean[DIRTY_MEMBRANE] > 0:
    print("FAIL: something is already infected before the player moved")
    ok = False

dirty = count("infect_dirty.ppm", wanted)
print("after:  player body %d, player rim %d, clean membrane %d, infected %d"
      % (dirty[PLAYER_BODY], dirty[PLAYER_RIM],
         dirty[CLEAN_MEMBRANE], dirty[DIRTY_MEMBRANE]))

if dirty[DIRTY_MEMBRANE] < 100:
    print("FAIL: standing in the cell did not infect it -- the mechanic, the "
          "tint switch or the held key is broken")
    ok = False
if dirty[PLAYER_BODY] < 30:
    print("FAIL: the player vanished while standing in a cell")
    ok = False

sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: infecteria renders from its sprites, and standing in a cell infects it"
  exit 0
fi
echo "FAIL: see above"
exit 1
