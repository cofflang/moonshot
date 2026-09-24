#!/usr/bin/env bash
#
# verify_mouse.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves the two things that make klick useful rather than merely correct:
# click-to-focus in kakel, and the ring-3 mouse syscall.
#
# The scene is a shell tile on the left and Gnista's demo in a tavla on the
# right. Movement and buttons are injected through QEMU's monitor
# (`mouse_move`, `mouse_button`), the same path verify_klick.sh drives.
#
#   1. spawn3 leaves focus on the shell, so a left press over the tavla must
#      move focus there, and a press back over the shell must move it back.
#      kakel logs every focus change with its cause, so the serial line is
#      the witness ("(click)"), and the pointer's position in the
#      screendumps confirms which tile was under it each time.
#   2. That focusing press must NOT also reach the program inside the
#      tavla. It is held down for four seconds, which is ample time for the
#      demo to steer entity 0 to the pointer, and no sprite may arrive.
#      This is the half that fails if a click ever goes back to doing two
#      things at once.
#   3. Once the tavla is focused, the NEXT press does steer the demo's
#      entity 0 toward the pointer (gnista.c0's mouse_poll() loop). After a
#      few seconds a sprite must sit at the pointer, and still be there a
#      second later -- the other three movers bounce around the same window
#      wearing the same sprite, and one of them passing by would not stay.
#      That only happens if SYS_MOUSE_POLL hands the program
#      window-relative coordinates and the button state.
#
# Checks 2 and 3 are the same measurement with the same tolerance, run on
# either side of one button release, and they must disagree. That is what
# makes this a test of the rule rather than of the demo.
#
# Screendumps are analysed by pixel, the way the other graphical checks are:
# the pointer by its exact fill colour, the sprite by its two frame colours.
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

sockfile=verify_mouse.sock
rm -f serial.log "$sockfile" mouse_*.ppm
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
    send("screendump %s" % name, settle=0.6)
def move(dx, dy, steps):
    for i in range(steps):
        send("mouse_move %d %d" % (dx, dy), settle=0.08)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("spawn3 gnista.elf"); typ(["ret"]); time.sleep(3.0)

# 1. Press over the unfocused tavla. This focuses it, and that is ALL it
#    may do: the press is held for four seconds, and the demo must not
#    steer anything with it.
move(14, 0, 10)                          # ~140 px right, into the tavla
move(0, 6, 10)                           # and a little down
time.sleep(0.5)
shot("mouse_tavla.ppm")
send("mouse_button 1", settle=0.3)
time.sleep(4.0)
shot("mouse_focusheld.ppm")
send("mouse_button 0", settle=0.3)
time.sleep(0.5)

# 2. Press again, without moving. The tavla is focused now, so this one is
#    the program's and the demo steers entity 0 to the pointer.
send("mouse_button 1", settle=0.3)
time.sleep(4.0)
shot("mouse_held.ppm")
time.sleep(1.0)
shot("mouse_held2.ppm")
send("mouse_button 0", settle=0.3)
time.sleep(0.5)

# 3. Click the shell tile: focus must come back.
move(-14, 0, 30)                         # ~420 px left, into the shell tile
time.sleep(0.5)
shot("mouse_shell.ppm")
send("mouse_button 1", settle=0.3); send("mouse_button 0", settle=0.3)
time.sleep(0.5)
sock.close()
EOF2
sleep 1

ok=1
echo "--- focus changes ---"
grep 'kakel focus' serial.log || true
clicks=$(grep -c 'kakel focus: win=.* (click)' serial.log || true)
if [ "$clicks" -lt 2 ]; then
  echo "FAIL: expected two click-driven focus changes, saw $clicks"
  ok=0
fi

python3 - <<'PY'
import sys
POINTER = (255, 255, 255)
SPRITE = ((255, 140, 0), (255, 220, 0))
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
def pixels_of(path, colours):
    w, h, buf = read_ppm(path)
    out = []
    for y in range(h):
        row = y * w
        for x in range(w):
            off = (row + x) * 3
            if (buf[off], buf[off+1], buf[off+2]) in colours:
                out.append((x, y))
    return out, w, h
def pointer(path):
    px, w, h = pixels_of(path, (POINTER,))
    return (min(px) if px else None), len(px), w
def nearest_sprite(path, p):
    """Distance from pointer p to the nearest sprite pixel, or None."""
    spr, _, _ = pixels_of(path, SPRITE)
    if not spr or p is None:
        return None
    return min(max(abs(x - p[0]), abs(y - p[1])) for x, y in spr)
ok = True
p_shell, n1, w = pointer("mouse_shell.ppm")
p_tavla, n2, _ = pointer("mouse_tavla.ppm")
p_held, n3, _ = pointer("mouse_held.ppm")
p_focus, n4, _ = pointer("mouse_focusheld.ppm")
print("pointer over tavla: %s, while held: %s, over shell tile: %s" % (p_tavla, p_held, p_shell))
if p_tavla is None or p_tavla[0] < w // 2:
    print("FAIL: the first click was not over the right (tavla) tile"); ok = False
if p_shell is None or p_shell[0] >= w // 2:
    print("FAIL: the second click was not over the left (shell) tile"); ok = False
# The demo stops steering within 2 px of the pointer on each axis and the
# sprite is 12 px across, so a steered sprite has pixels within a few px of
# the hot spot; 16 leaves room for the pointer glyph covering some of it.
# The same 16 is the threshold both checks below use.
NEAR = 16

d0 = nearest_sprite("mouse_focusheld.ppm", p_focus)
print("nearest sprite pixel after 4s of the FOCUSING press: %s px" % (d0,))
if d0 is not None and d0 <= NEAR:
    print("FAIL: the focusing click was also delivered to the program -- a")
    print("      sprite followed a press whose only job was to focus the")
    print("      window. See klick_focus_click in klick.c0.")
    ok = False

d1 = nearest_sprite("mouse_held.ppm", p_held)
d2 = nearest_sprite("mouse_held2.ppm", p_held)
print("nearest sprite pixel to the pointer: %s px after 4s held, %s px a second later" % (d1, d2))
if d1 is None or d1 > NEAR or d2 is None or d2 > NEAR:
    print("FAIL: no sprite stayed at the pointer -- mouse_poll() is not steering entity 0"); ok = False
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || ok=0

echo
if [ "$ok" -eq 1 ]; then
  echo "PASS: the focusing click only focuses, the next one reaches the program,"
  echo "      and click-to-focus works both ways"
  exit 0
fi
echo "FAIL: see above"
exit 1
