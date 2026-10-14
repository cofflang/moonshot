#!/usr/bin/env bash
#
# verify_infecteria_heal.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Antibacteria heal infected cells when the player is not close by.
#
#   1. Standing in the cell below the start infects it, so the screen shows
#      the infected tint.
#   2. The player steps about three hundred pixels up, out of the
#      antibacteria's short hunting range but with the cell still in view,
#      and stays there.
#   3. Within forty seconds a screenshot shows no infected tint any more,
#      clean cells in view and the player alive. Screenshots are taken every
#      two seconds and the first clean one counts, so the test does not
#      depend on exactly when the antibacterium arrives.
#
# The world is fixed by infecteria.seed, as in verify_infecteria.sh, and
# starts with no antibacteria at all (the file's second number), so the
# one that heals is the one that arrives fifteen seconds in, at least a
# screen away. Only the player infects cells here, since no factory is
# built, so an infected tint that goes away can only have been healed.

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

sockfile=verify_infecteria_heal.sock
rm -f serial.log "$sockfile" heal_*.ppm
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
# The second number starts it with no antibacteria. The first one arrives
# after fifteen seconds, at least a screen away from the player, so the one
# this test watches comes to the cell rather than chasing the player off it
# first.
word("make infecteria.seed"); typ(["ret"]); time.sleep(0.6)
word("write infecteria.seed 1 0"); typ(["ret"]); time.sleep(0.6)
word("start infecteria.elf"); typ(["ret"]); time.sleep(4.0)
# start leaves focus on the shell, so the arrow keys would drive the shell.
typ(["alt-tab"]); time.sleep(1.5)
# The game opens on its title scene; space starts the world.
typ(["spc"]); time.sleep(1.5)
# Onto the cell below the start, and stand there while it is infected.
send("sendkey down 1200", settle=1.8)
time.sleep(2.0)
shot("heal_infected.ppm")
# About three hundred pixels up, in one-second holds, the cell still on
# screen. Then watch.
for _ in range(3):
    send("sendkey up 1000", settle=1.0)
for k in range(20):
    time.sleep(2.0)
    shot("heal_%02d.ppm" % k)

sock.close()
EOF2
sleep 1

python3 - <<'PY'
import sys
COL_BG      = (0x10, 0x18, 0x20)
COL_CELL    = (0x60, 0x80, 0xC0)
COL_INFECT  = (0xC0, 0x60, 0x40)
PLAYER_BODY = (0x40, 0xFF, 0x80)
DIM_TEXT    = (0x78, 0x90, 0xA0)
def blend(a, b):
    return tuple((x + y) // 2 for x, y in zip(a, b))
CLEAN = blend(COL_CELL, COL_BG)
DIRTY = blend(COL_INFECT, COL_BG)

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

def count(path):
    w, h, buf = read_ppm(path)
    tally = {CLEAN: 0, DIRTY: 0, DIM_TEXT: 0}
    for i in range(0, w * h * 3, 3):
        c = (buf[i], buf[i+1], buf[i+2])
        if c in tally:
            tally[c] += 1
    return tally

ok = True
a = count("heal_infected.ppm")
print("standing in the cell: infected membrane %d, clean %d" % (a[DIRTY], a[CLEAN]))
if a[DIRTY] < 100:
    print("FAIL: the cell below the start never got infected, so there was nothing to heal")
    ok = False
healed = None
for k in range(20):
    c = count("heal_%02d.ppm" % k)
    if c[DIM_TEXT] > 0:
        print("after %d s the player is dead" % (2 * k + 2))
        break
    if c[DIRTY] == 0 and c[CLEAN] >= 100:
        healed = 2 * k + 2
        break
if ok and healed is None:
    print("FAIL: the infected cell was never healed while the player stood clear")
    ok = False
elif ok:
    print("healed within %d s of stepping away, player alive" % healed)
sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: antibacteria heal a cell the player left infected"
  exit 0
fi
echo "FAIL: see above"
exit 1
