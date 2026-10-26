#!/usr/bin/env bash
#
# verify_infecteria_win.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Infecteria is won by taking every cell, and says so.
#
#   1. While playing, the counter in the top-left corner reads
#      "cells 0 of 1   eaten 0   factories 0", checked pixel for pixel
#      against the kernel font, read out of punkt.c0 the way
#      verify_utsikt_address.sh does it.
#   2. Infecting the only cell and eating it with e ends the game won, the
#      end screen saying INFECTED in large green letters, not CLEARED in red.
#
# infecteria.seed's second and third numbers give a world with no
# antibacteria and a single cell, the one below the start, so the whole game
# is one cell long.

set -u
cd "$(dirname "$0")/.."

./build.sh || exit 1

mkdir -p out && cd out

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
if [ ! -f moonshot.iso ]; then
  echo "FAIL: grub-mkrescue did not produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

sockfile=verify_infecteria_win.sock
rm -f serial.log "$sockfile" win_*.ppm
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
# A fixed world. Infecteria builds its layout from infecteria.seed when the
# file exists, so every run of this test plays the same world, and no layout
# can make the checks below fail for reasons that have nothing to do with the
# game being broken.
# The second and third numbers give it no antibacteria and a single cell.
word("make infecteria.seed"); typ(["ret"]); time.sleep(0.6)
word("write infecteria.seed 1 0 1"); typ(["ret"]); time.sleep(0.6)
word("start infecteria.elf"); typ(["ret"]); time.sleep(4.0)
typ(["alt-tab"]); time.sleep(1.5)
typ(["spc"]); time.sleep(1.5)
shot("win_play.ppm")
# Onto the cell, wait for it to be fully infected, and eat it.
send("sendkey down 550", settle=1.2)
time.sleep(2.0)
typ(["e"]); time.sleep(1.5)
shot("win_end.ppm")

sock.close()
EOF2
sleep 1

python3 - <<'PY'
import re, sys
HUD = (0xC8, 0xD8, 0xE0)
GREEN = (0x40, 0xFF, 0x80)
RED = (0xE0, 0x40, 0x40)

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos+1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    return fields[0], fields[1], data[pos:]

def pixels(path, colour):
    w, h, buf = read_ppm(path)
    out = set()
    for i in range(0, w * h * 3, 3):
        if (buf[i], buf[i+1], buf[i+2]) == colour:
            out.add(((i // 3) % w, (i // 3) // w))
    return out

src = open("../kernel/screen/punkt.c0").read()
def table(fn):
    body = src[src.index("int %s(int ch) {" % fn):]
    body = body[:body.index("\n}\n")]
    out = {}
    for key, val in re.findall(r"if \(ch == ('(?:\\.|.)'|\d+)\)\s*\{ return (0x[0-9A-Fa-f]+); \}", body):
        ch = int(key) if key[0] != "'" else ord(key[1:-1].replace("\\", ""))
        out[ch] = int(val, 16)
    return out
hi, lo = table("font_hi"), table("font_lo")
def render(text):
    lit = set()
    for k, ch in enumerate(text):
        for r in range(8):
            word = hi.get(ord(ch), 0) if r < 4 else lo.get(ord(ch), 0)
            bits = (word >> ((3 - r if r < 4 else 7 - r) * 8)) & 255
            for c in range(8):
                if (bits >> (7 - c)) & 1:
                    lit.add((k * 8 + c, r))
    return lit

ok = True
# 1. The counter. Its colour appears nowhere else while playing, so its
# pixels are the text, and lining up their top-left with the rendered
# text's top-left compares the two exactly.
got = pixels("win_play.ppm", HUD)
want = render("cells 0 of 1   eaten 0   factories 0")
if not got:
    print("FAIL: no counter on screen while playing")
    ok = False
else:
    gx, gy = min(x for x, y in got), min(y for x, y in got)
    wx, wy = min(x for x, y in want), min(y for x, y in want)
    shifted = {(x - gx + wx, y - gy + wy) for x, y in got}
    if shifted != want:
        print("FAIL: the counter does not read 'cells 0 of 1   eaten 0   factories 0'"
              " (%d pixels missing, %d extra)" % (len(want - shifted), len(shifted - want)))
        ok = False
    else:
        print("the counter reads 'cells 0 of 1   eaten 0   factories 0', all %d pixels" % len(want))

# 2. The end screen. The title is four times the font's size, so it is
# hundreds of pixels of one colour, where the player is a few dozen.
g, r = len(pixels("win_end.ppm", GREEN)), len(pixels("win_end.ppm", RED))
print("end screen: green %d, red %d" % (g, r))
if g < 300 or r > 300:
    print("FAIL: eating the last cell did not bring up a won end screen")
    ok = False
sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: the counter counts and taking every cell wins"
  exit 0
fi
echo "FAIL: see above"
exit 1
