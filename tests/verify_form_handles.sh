#!/usr/bin/env bash
#
# verify_form_handles.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# form's handles and picking more than one side, driven by the mouse. The
# new cube sits at the middle, so its corners' x add up to nothing. Tab
# picks a side and the red handle (x) is dragged a quarter more than its
# own length on the screen, 15 sixteenths of a unit.
#
#   1. Saved, the corners' x, added up by test/et25.elf, are 4 * 14 to
#      4 * 16 sixteenths, the side's four corners moved along x by whole
#      sixteenths (et25 says 255 when one is off them), and nothing else.
#   2. With Shift held, a click on another side adds it, and 3 colours
#      both, so et24 counts four yellow faces, two sides of two triangles.
set -u
cd "$(dirname "$0")/.."

./tools/gen_elf_tests.sh >/dev/null || exit 1
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

sockfile=verify_form_handles.sock
rm -f serial.log "$sockfile" handles_*.ppm
dd if=/dev/zero of=handles.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=handles.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile" handles.img; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'PY'
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
sock.setblocking(False)
time.sleep(0.3)
def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    try:
        sock.recv(65536)
    except BlockingIOError:
        pass
def typ(keys, gap=0.1):
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
def where(img, test):
    w, h, d = img
    return [((i // 3) % w, (i // 3) // w) for i in range(0, len(d), 3) if test(d[i], d[i+1], d[i+2])]
pos = [0, 0]
def move_to(tx, ty):
    for attempt in range(6):
        ptr = where(shot("handles_ptr.ppm"), lambda r, g, b: (r, g, b) == (255, 255, 255))
        if not ptr: return
        px, py = min(ptr)
        dx, dy = tx - px, ty - py
        if abs(dx) <= 1 and abs(dy) <= 1: break
        steps = max(abs(dx), abs(dy)) // 8 + 1
        for _ in range(steps):
            send("mouse_move %d %d" % (dx // steps, dy // steps), settle=0.03)
        time.sleep(0.3)
def glide(dx, dy):
    steps = max(abs(dx), abs(dy)) // 6 + 1
    sx = sy = 0
    for k in range(1, steps + 1):
        nx, ny = dx * k // steps, dy * k // steps
        send("mouse_move %d %d" % (nx - sx, ny - sy), settle=0.05)
        sx, sy = nx, ny

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("start form.elf ship.form"); typ(["ret"]); time.sleep(3.5)
typ(["alt-tab"]); time.sleep(0.5)
typ(["right"] * 16); time.sleep(0.5)
typ(["tab"]); time.sleep(0.8)

# The red handle's end, a 9x9 square of 0xe04a3a, and its shaft's far end,
# the red pixel furthest from it.
img = shot("handles_picked.ppm")
RED = (0xe0, 0x4a, 0x3a)
red = set(where(img, lambda r, g, b: (r, g, b) == RED))
box = [p for p in red if all((p[0] + i, p[1] + j) in red for i in range(9) for j in range(9))]
if box:
    bx, by = box[0][0] + 4, box[0][1] + 4
    base = max(red, key=lambda p: (p[0] - bx) ** 2 + (p[1] - by) ** 2)
    print("   red handle end %d,%d, base %d,%d" % (bx, by, base[0], base[1]))
    move_to(bx, by)
    send("mouse_button 1", settle=0.3)
    glide((bx - base[0]) * 5 // 4, (by - base[1]) * 5 // 4)
    time.sleep(0.3)
    send("mouse_button 0", settle=0.3)
    time.sleep(0.5)
else:
    print("   no red handle on screen")

# Another side, the blue face pixels well away from the picked side's
# outline (COL_PICK) and from the handles, nearest their own middle.
img = shot("handles_moved.ppm")
pick = where(img, lambda r, g, b: (r, g, b) == (0xff, 0xd8, 0x4a))
if pick:
    x0, x1 = min(x for x, y in pick) - 10, max(x for x, y in pick) + 10
    y0, y1 = min(y for x, y in pick) - 10, max(y for x, y in pick) + 10
    hand = where(img, lambda r, g, b: (r, g, b) in ((0xe0, 0x4a, 0x3a), (0x5a, 0xc8, 0x5a), (0x4a, 0x8a, 0xe8)))
    w = img[0]
    blue = [p for p in where(img, lambda r, g, b: b > 90 and b > r + 40 and b > g + 10)
            if p[0] >= w // 2 and not (x0 <= p[0] <= x1 and y0 <= p[1] <= y1)
            and all(abs(p[0] - q[0]) > 12 or abs(p[1] - q[1]) > 12 for q in hand[::7])]
    if blue:
        cx = sum(x for x, y in blue) // len(blue)
        cy = sum(y for x, y in blue) // len(blue)
        tx, ty = min(blue, key=lambda p: (p[0] - cx) ** 2 + (p[1] - cy) ** 2)
        print("   shift+click at %d,%d" % (tx, ty))
        move_to(tx, ty)
        send("sendkey shift 1500", settle=0.3)
        send("mouse_button 1", settle=0.2)
        send("mouse_button 0", settle=0.2)
        time.sleep(1.5)
    else:
        print("   no other side found")
typ(["3"]); time.sleep(0.8)
shot("handles_two.ppm")
typ(["f2"]); time.sleep(0.8)
typ(["alt-w"]); time.sleep(1.5)
word("start test/et25.elf"); typ(["ret"]); time.sleep(2.0)
word("start test/et24.elf"); typ(["ret"]); time.sleep(2.0)
sock.close()
PY
sleep 1

ok=1
codes=$(grep -ao '^\[syscall\] exit code=[0-9]*' serial.log | grep -o '[0-9]*$' | tr '\n' ' ')
echo "exit codes: $codes"
# The last two, et25 and then et24.
read -r after yellow <<<"$(echo $codes | awk '{print $(NF-1), $NF}')"
after=${after:-0}; yellow=${yellow:-0}
moved=$((after - 128))
if [ "$after" != 255 ] && [ "$moved" -ge 56 ] && [ "$moved" -le 64 ] && [ $((moved % 4)) -eq 0 ]; then
  echo "  ok   1. the handle moved the side's four corners $((moved / 4)) sixteenths along x"
else
  echo "  FAIL 1. corners' x add up to $after - 128 (255 is off the sixteenths), expected 56 to 64"; ok=0
fi
if [ "$yellow" = 4 ]; then
  echo "  ok   2. Shift+click added a second side, both coloured, four yellow faces"
else
  echo "  FAIL 2. et24 counted $yellow yellow faces, not 4"; ok=0
fi
if [ "$ok" -eq 1 ]; then echo "PASS: form's handles move what is picked on the grid, and Shift+click adds to it"; exit 0; fi
exit 1
