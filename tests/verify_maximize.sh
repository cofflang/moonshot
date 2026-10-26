#!/usr/bin/env bash
#
# verify_maximize.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Maximizing a window, checked from the screen.
#
#   1. With the shell on the left and hylla on the right, Alt+M on the shell
#      fills the screen with it, and hylla's colour is gone.
#   2. Alt+M again brings the layout back, and hylla has drawn its half
#      again, though hylla only draws when its window changes, since a
#      window coming back is nudged to draw.
#   3. With Infecteria playing on the right and the shell maximized, the
#      game draws nothing, the right half stays the shell's.
#   4. A click on Infecteria's [+] box maximizes it, so it shows on the left
#      half too, and Alt+M brings the shell back on the left.
#   5. A click on its [x] box closes it, and the shell takes the screen.
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

sockfile=verify_maximize.sock
rm -f serial.log "$sockfile" max_*.ppm
rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'PY'
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
def shot(name):
    send("screendump %s" % name, settle=1.0)
    data = open(name, "rb").read()
    head = data.split(b"\n", 3)
    w, h = map(int, head[1].split())
    return w, h, head[3]
def count(img, x0, x1, y0, y1, pred):
    w, h, d = img
    n = 0
    for y in range(y0, y1, 4):
        for x in range(x0, x1, 4):
            i = (y * w + x) * 3
            if pred((d[i], d[i + 1], d[i + 2])):
                n += 1
    return n
pos = [512, 384]
def park():
    for _ in range(12):
        send("mouse_move -100 -100", settle=0.04)
    pos[0] = pos[1] = 0
def move_to(x, y):
    while pos[0] != x or pos[1] != y:
        dx = max(-100, min(100, x - pos[0]))
        dy = max(-100, min(100, y - pos[1]))
        send("mouse_move %d %d" % (dx, dy), settle=0.04)
        pos[0] += dx
        pos[1] += dy

HYLLA = (0x1c, 0x28, 0x38)
fails = []
def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("start hylla.elf"); typ(["ret"]); time.sleep(3.0)
park()
a = shot("max_a.ppm")
check(count(a, 600, 1000, 100, 600, lambda c: c == HYLLA) > 1000,
      "0. hylla is on the right half")
typ(["alt-m"]); time.sleep(1.5)
b = shot("max_b.ppm")
check(count(b, 0, 1024, 20, 700, lambda c: c == HYLLA) == 0,
      "1. Alt+M on the shell hides hylla")
typ(["alt-m"]); time.sleep(2.0)
c = shot("max_c.ppm")
check(count(c, 600, 1000, 100, 600, lambda c: c == HYLLA) > 1000,
      "2. Alt+M again and hylla has drawn its half again")

typ(["alt-tab"]); time.sleep(0.5)
typ(["alt-w"]); time.sleep(1.0)
word("start infecteria.elf"); typ(["ret"]); time.sleep(4.0)
typ(["alt-m"]); time.sleep(2.0)
d = shot("max_d.ppm")
# The shell is black, with its text at the top left. Anything that is not
# black on the right half is the game drawing, whose background is slate.
lit = lambda c: sum(c) > 60
check(count(d, 520, 1020, 20, 700, lit) == 0,
      "3. the game behind the maximized shell draws nothing")
typ(["alt-m"]); time.sleep(2.0)
e = shot("max_e.ppm")
check(count(e, 520, 1020, 20, 700, lit) > 5000,
      "3. and shows again once the layout is back")
park()
move_to(971, 3)
send("mouse_button 1", settle=0.3)
send("mouse_button 0", settle=0.3)
time.sleep(2.0)
f = shot("max_f.ppm")
check(count(f, 10, 500, 20, 700, lit) > 5000,
      "4. a click on the game's [+] fills the screen with it")
typ(["alt-m"]); time.sleep(2.0)
g = shot("max_g.ppm")
check(count(g, 10, 500, 20, 700, lit) < 200,
      "4. Alt+M brings the shell back on the left")
park()
move_to(1003, 3)
send("mouse_button 1", settle=0.3)
send("mouse_button 0", settle=0.3)
time.sleep(2.0)
h = shot("max_h.ppm")
check(count(h, 520, 1020, 20, 700, lit) < 200,
      "5. a click on the game's [x] closes it")
sock.close()
open("max_steps.result", "w").write("FAIL\n" if fails else "PASS\n")
PY

ok=1
[ "$(cat max_steps.result 2>/dev/null)" = "PASS" ] || ok=0
rm -f max_steps.result
if grep -q 'PANIC' serial.log; then echo "FAIL: kernel panic"; ok=0; fi
if [ "$ok" -eq 1 ]; then
  echo "PASS: a window fills the screen and gives it back"
  exit 0
fi
echo "--- serial ---"
grep -aE 'maximized|focus|\[tavla\]' serial.log | tail -20
exit 1
