#!/usr/bin/env bash
#
# verify_pensel.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Draws a two-frame sprite in pensel and checks every step from the screen.
#
#   1. `draw hero.spr` starts pensel on a new 16x16 canvas, in a window of
#      its own that has the focus.
#   2. Red is picked from the palette and painted at (2,2).
#   3. n adds frame 2 as a copy, so (2,2) is red there too.
#   4. (5,5) is painted in frame 2. Right-click erases (2,2) in frame 2, and
#      that cell now shows frame 1's red faintly (the onion skin), and neither
#      red nor the bare checkerboard.
#   5. n then d, so a third frame is added and deleted again.
#   6. Left goes back to frame 1, (2,2) red, (5,5) empty.
#   7. Ctrl+Z takes back the last stroke and Ctrl+Y puts it back.
#   8. F2 saves 24 + 2 frames * 16 * 16 * 4 = 2072 bytes, which the shell's
#      count shows once Alt+W has closed the window.
#   9. `draw hero.spr` again, and both frames come back from the file, frame
#      1 with (2,2) and frame 2 with (5,5).
#
# The canvas is found from the screen. An empty cell is a checkerboard of
# (40,40,40) and (60,60,60). pensel sizes its cells to the window, so the
# cell size is measured, the run of (40,40,40) along the first cell's top
# row plus its one-pixel grid line.

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

rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

sockfile=verify_pensel.sock
rm -f serial.log "$sockfile" pensel_*.ppm
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
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash", ",": "comma"}
    typ([keymap.get(c, c) for c in s])

def shot(name):
    send("screendump %s" % name, settle=1.0)
    data = open(name, "rb").read()
    head = data.split(b"\n", 3)
    w, h = map(int, head[1].split())
    return w, h, head[3]

def px(img, x, y):
    w, h, d = img
    i = (y * w + x) * 3
    return d[i], d[i + 1], d[i + 2]

pos = [512, 384]
def park():
    for _ in range(9):
        send("mouse_move -100 -100", settle=0.04)
    pos[0] = pos[1] = 0

def move_to(x, y):
    while pos[0] != x or pos[1] != y:
        dx = max(-100, min(100, x - pos[0]))
        dy = max(-100, min(100, y - pos[1]))
        send("mouse_move %d %d" % (dx, dy), settle=0.04)
        pos[0] += dx
        pos[1] += dy

def click(x, y, button=1):
    move_to(x, y)
    send("mouse_button %d" % button, settle=0.3)
    send("mouse_button 0", settle=0.3)

DARK, LIGHT, RED = (40, 40, 40), (60, 60, 60), (200, 40, 40)
ZOOM = [14]
fails = []
def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)

def canvas(img):
    w, h, _ = img
    for y in range(h - 1):
        for x in range(w - 1):
            if px(img, x, y) != DARK or (x > 0 and px(img, x - 1, y) == DARK):
                continue
            run = 0
            while x + run < w and px(img, x + run, y) == DARK:
                run += 1
            z = run + 1
            if (z >= 4 and x + z < w and y + z < h and px(img, x + z, y) == LIGHT
                    and px(img, x, y + z) == LIGHT):
                ZOOM[0] = z
                return x, y
    return None

def cell(org, cx, cy):
    z = ZOOM[0]
    return org[0] + cx * z + z // 2, org[1] + cy * z + z // 2

def at(img, org, cx, cy):
    return px(img, *cell(org, cx, cy))

def empty(c):
    return c in (DARK, LIGHT)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("draw hero.spr"); typ(["ret"]); time.sleep(1.5)
park()

a = shot("pensel_a.ppm")
org = canvas(a)
check(org is not None, "1. a 16x16 canvas on screen")
if org is None:
    sys.exit(1)
print("     canvas at %d,%d, cells of %d" % (org[0], org[1], ZOOM[0]))

# The palette, two columns of 20-pixel swatches, 12 pixels right of the
# canvas. Red is swatch 4, column 0, row 2.
pal = org[0] + 16 * ZOOM[0] + 12
click(pal + 9, org[1] + 2 * 20 + 9)
click(*cell(org, 2, 2))
park()
b = shot("pensel_b.ppm")
check(at(b, org, 2, 2) == RED, "2. (2,2) painted red in frame 1")

typ(["n"]); time.sleep(0.8)
park()
c = shot("pensel_c.ppm")
check(at(c, org, 2, 2) == RED, "3. frame 2 starts as a copy of frame 1")

click(*cell(org, 5, 5))
click(*cell(org, 2, 2), button=2)
park()
d = shot("pensel_d.ppm")
onion = at(d, org, 2, 2)
print("     (2,2) in frame 2 after erasing: %s" % (onion,))
check(at(d, org, 5, 5) == RED, "4. (5,5) painted in frame 2")
check(onion != RED and not empty(onion) and onion[0] > onion[1],
      "4. the erased (2,2) shows frame 1's red faintly (onion skin)")

typ(["n"]); time.sleep(0.6)
typ(["d"]); time.sleep(0.6)
typ(["left"]); time.sleep(0.8)
park()
e = shot("pensel_e.ppm")
check(at(e, org, 2, 2) == RED and empty(at(e, org, 5, 5)),
      "5-6. after adding and deleting a frame, frame 1 is still itself")

click(*cell(org, 9, 9))
typ(["ctrl-z"]); time.sleep(0.6)
park()
u = shot("pensel_u.ppm")
typ(["ctrl-y"]); time.sleep(0.6)
park()
r = shot("pensel_r.ppm")
check(empty(at(u, org, 9, 9)) and at(r, org, 9, 9) == RED,
      "7. ctrl-z takes the last stroke back and ctrl-y puts it back")
typ(["ctrl-z"]); time.sleep(0.6)
typ(["f2"]); time.sleep(0.8)
typ(["alt-w"]); time.sleep(1.5)
word("count hero.spr"); typ(["ret"]); time.sleep(1.0)
word("draw hero.spr"); typ(["ret"]); time.sleep(2.5)
park()
f = shot("pensel_f.ppm")
org2 = canvas(f) or org
check(at(f, org2, 2, 2) == RED and empty(at(f, org2, 5, 5)), "9. frame 1 reloaded from the file")
typ(["right"]); time.sleep(0.8)
park()
g = shot("pensel_g.ppm")
check(at(g, org2, 5, 5) == RED and not empty(at(g, org2, 2, 2)) and at(g, org2, 2, 2) != RED,
      "9. frame 2 reloaded, (5,5) painted, (2,2) empty with the onion skin")
typ(["alt-w"]); time.sleep(0.5)

sock.close()
open("pensel_steps.result", "w").write("FAIL\n" if fails else "PASS\n")
EOF

ok=1
[ "$(cat pensel_steps.result 2>/dev/null)" = "PASS" ] || ok=0
rm -f pensel_steps.result

if grep -aqE '^\[sh\] [0-9]+ lines?, [0-9]+ words?, 2072 bytes' serial.log; then
  echo "  ok   8. saved two frames, 2072 bytes"
else
  echo "  FAIL 8. the save was not 2072 bytes"
  grep -a '^\[sh\] [0-9]* line' serial.log
  ok=0
fi
if grep -q 'PANIC' serial.log; then echo "FAIL: kernel panic"; ok=0; fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: pensel draws, adds, deletes, saves and reloads frames"
  exit 0
fi
echo "FAIL: pensel frames"
exit 1
