#!/usr/bin/env bash
#
# verify_infecteria_scenes.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Infecteria's scenes, built on Gnista's scene_run, with title, play, the end
# screen, play again, quit.
#
#   1. The game opens on its title, INFECTERIA in large green letters.
#   2. Space starts a world, the title is gone and cells are on screen.
#   3. Standing still, the antibacteria close in and the player dies. The
#      game does not exit; the end screen comes up, CLEARED in large red
#      letters with the dim "space to play again" line under the stats.
#   4. Space plays again, a fresh world, no end screen.
#   5. Esc quits, and the task exits with code 0.
#
# The world is fixed by infecteria.seed, so the antibacteria start in the
# same places every run. Scenes are recognised by colours only they use in
# quantity, the title's green (the player is the same green, but 16 pixels
# across, not a word four times the font's size), the end screen's red (an
# antibacterium is that red too, at 18 pixels), and the dim text colour that
# only the title and end screens use.

set -u
cd "$(dirname "$0")"

./build.sh || exit 1

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1

rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

sockfile=verify_inf_scenes.sock
rm -f serial.log "$sockfile" inf_scene.ppm
qemu-system-x86_64 -cdrom moonshot.iso \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'EOF'
import socket, sys, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
sock.setblocking(False)
time.sleep(0.2)

def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    try:
        sock.recv(65536)
    except BlockingIOError:
        pass

def typ(keys, gap=0.08):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])

GREEN = (64, 255, 128)     # the title, and the player
RED = (224, 64, 64)        # CLEARED, and an antibacterium
DIM = (120, 144, 160)      # the title's and the end screen's small print
CELL = (56, 76, 112)       # a clean cell's membrane, from verify_infecteria

def counts():
    send("screendump inf_scene.ppm", settle=1.0)
    data = open("inf_scene.ppm", "rb").read()
    head = data.split(b"\n", 3)
    d = head[3]
    found = {GREEN: 0, RED: 0, DIM: 0, CELL: 0}
    for i in range(0, len(d), 3):
        c = (d[i], d[i + 1], d[i + 2])
        if c in found:
            found[c] += 1
    return found

fails = []
def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("make infecteria.seed"); typ(["ret"]); time.sleep(0.6)
word("write infecteria.seed 1"); typ(["ret"]); time.sleep(0.6)
word("spawn3 infecteria.elf"); typ(["ret"]); time.sleep(3.0)
typ(["alt-tab"]); time.sleep(1.0)

c = counts()
print("     title: green %d, dim %d" % (c[GREEN], c[DIM]))
check(c[GREEN] > 500 and c[DIM] > 100, "1. the title scene")

typ(["spc"]); time.sleep(2.0)
c = counts()
print("     play: green %d, dim %d, cell %d" % (c[GREEN], c[DIM], c[CELL]))
check(c[GREEN] < 200 and c[DIM] == 0 and c[CELL] > 100, "2. space starts a world")

# Stand still until the end screen comes up. Antibacteria start a screen or
# more away and are slower than the player, then take four seconds of
# contact to kill, well under a minute, with a fixed world the same every run.
over = None
t0 = time.time()
while time.time() - t0 < 90:
    time.sleep(3.0)
    c = counts()
    if c[RED] > 500 and c[DIM] > 100:
        over = time.time() - t0
        break
print("     end screen after %s s: red %d, dim %d" % (
    "%.0f" % over if over is not None else "no end within 90", c[RED], c[DIM]))
check(over is not None, "3. dying brings up the end screen instead of exiting")

typ(["spc"]); time.sleep(2.0)
c = counts()
print("     again: red %d, dim %d, cell %d" % (c[RED], c[DIM], c[CELL]))
check(c[DIM] == 0 and c[CELL] > 100, "4. space plays again")

typ(["esc"]); time.sleep(1.5)
sock.close()
open("inf_scenes.result", "w").write("FAIL\n" if fails else "PASS\n")
EOF

ok=1
[ "$(cat inf_scenes.result 2>/dev/null)" = "PASS" ] || ok=0
rm -f inf_scenes.result
if grep -q '\[syscall\] exit code=0' serial.log; then
  echo "  ok   5. Esc quits: exit code 0"
else
  echo "  FAIL 5. Esc did not end the game"
  ok=0
fi
if grep -q 'PANIC' serial.log; then echo "FAIL: kernel panic"; ok=0; fi
if grep -q 'lager\] dealloc: not a live block' serial.log; then
  echo "FAIL: infecteria freed something it did not own"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: title, play, end screen, play again, quit"
  exit 0
fi
echo "FAIL: infecteria scenes"
exit 1
