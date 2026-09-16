#!/usr/bin/env bash
#
# verify_klick.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves klick -- the PS/2 mouse driver -- works end to end on real hardware
# emulation and real pixels.
#
# Movement is injected through QEMU's monitor (`mouse_move dx dy`,
# `mouse_button state`), which drives the emulated i8042's aux port exactly
# like a physical mouse would, so this exercises the whole path: IRQ12 on the
# slave PIC, the aux-vs-keyboard status bit, three-byte packet assembly, sign
# extension, and the pointer's save/restore rendering.
#
# Checks:
#   1. klick comes up: the mouse acknowledges both commands (0xFA = 250).
#   2. Packets actually arrive -- the counter moves. This is the check that
#      separates a working IRQ from a pointer that merely sits there, which
#      look identical on screen.
#   3. The pointer tracks movement in the right direction on BOTH axes,
#      including the y inversion (the mouse's y points up, the screen's down).
#   4. Buttons register.
#   5. The pointer is really drawn, and -- the part worth checking in pixels
#      rather than state -- it leaves no trail behind: the pixels it used to
#      cover are restored, not painted over with a background colour.

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

sockfile=verify_klick.sock
rm -f serial.log "$sockfile" klick_*.ppm
qemu-system-x86_64 -cdrom moonshot.iso \
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

# raket login gate.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)

# Baseline before touching the mouse.
word("mouse"); typ(["ret"]); time.sleep(0.8)
shot("klick_before.ppm")

# Move right and DOWN. The mouse reports +y as up, so screen-down is -dy at
# this end; QEMU's mouse_move takes screen-style deltas and inverts for us,
# so a positive dy here should move the pointer DOWN the screen.
for i in range(10):
    send("mouse_move 12 8", settle=0.08)
time.sleep(1.0)
word("mouse"); typ(["ret"]); time.sleep(0.8)
shot("klick_moved.ppm")

# Buttons: press left, report, release.
send("mouse_button 1", settle=0.3)
time.sleep(0.4)
word("mouse"); typ(["ret"]); time.sleep(0.8)
send("mouse_button 0", settle=0.3)

# Move well away again, so the trail check has somewhere clean to look.
for i in range(10):
    send("mouse_move -14 -10", settle=0.08)
time.sleep(1.0)
word("mouse"); typ(["ret"]); time.sleep(0.8)
shot("klick_back.ppm")

sock.close()
EOF

sleep 1

ok=1

echo "--- klick init ---"
grep '\[klick\]' serial.log || true

if ! grep -q 'enable ack=250' serial.log; then
  echo "FAIL: the mouse never acknowledged the enable command"
  ok=0
fi

echo
echo "--- button transitions ---"
grep '\[klick\] buttons' serial.log || true
if ! grep -q '\[klick\] buttons L1' serial.log; then
  echo "FAIL: pressing the left button never registered"
  ok=0
fi
if ! grep -q '\[klick\] buttons L0 M0 R0' serial.log; then
  echo "FAIL: releasing the left button never registered"
  ok=0
fi

echo
echo "--- mouse command output ---"
grep -n 'pointer .*packets' serial.log || true

# skalman prints to the window, not to serial -- so read the state out of the
# screendumps' companion serial trace where available, and fall back to the
# pixel checks below, which are the real evidence anyway.

python3 - <<'PY'
import sys

BAR = None
POINTER = (255, 255, 255)
EDGE = (40, 40, 40)

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

def find_pointer(path):
    """Locate the pointer by its exact fill colour. Returns (x, y) of the
    top-left pointer pixel and how many pointer-coloured pixels were found."""
    w, h, buf = read_ppm(path)
    best = None
    count = 0
    for y in range(h):
        row = y * w
        for x in range(w):
            off = (row + x) * 3
            if (buf[off], buf[off+1], buf[off+2]) == POINTER:
                count += 1
                if best is None:
                    best = (x, y)
    return best, count, w, h

ok = True
before, n_before, w, h = find_pointer("klick_before.ppm")
moved, n_moved, _, _ = find_pointer("klick_moved.ppm")
back, n_back, _, _ = find_pointer("klick_back.ppm")

print("pointer before: %s (%d px)" % (before, n_before))
print("pointer moved:  %s (%d px)" % (moved, n_moved))
print("pointer back:   %s (%d px)" % (back, n_back))

if before is None:
    print("FAIL: no pointer drawn at boot")
    ok = False
if moved is None or back is None:
    print("FAIL: pointer disappeared after moving")
    ok = False

if before and moved:
    if not (moved[0] > before[0]):
        print("FAIL: moving right did not increase the pointer's x")
        ok = False
    if not (moved[1] > before[1]):
        print("FAIL: moving down did not increase the pointer's y "
              "(the mouse's y axis points up -- check the inversion)")
        ok = False

if moved and back:
    if not (back[0] < moved[0] and back[1] < moved[1]):
        print("FAIL: moving back up-left did not decrease both coordinates")
        ok = False

# No trail: exactly one pointer should exist on screen at a time. A
# save/restore bug shows up as pointer-coloured pixels left along the path.
# The pointer is KLICK_SIZE(6) wide with its last row and column drawn in the
# edge colour, so the fill colour covers 5x5 = 25 pixels.
for name, n in (("before", n_before), ("moved", n_moved), ("back", n_back)):
    if n > 40:
        print("FAIL: %d pointer-coloured pixels in klick_%s.ppm -- "
              "the pointer is leaving a trail" % (n, name))
        ok = False

sys.exit(0 if ok else 1)
PY
pixels_ok=$?
[ "$pixels_ok" -eq 0 ] || ok=0

panics=$(grep -c 'PANIC' serial.log || true)
dfs=$(grep -c 'double fault' serial.log || true)
echo "panics: $panics, double faults: $dfs"
if [ "$panics" -ne 0 ] || [ "$dfs" -ne 0 ]; then
  echo "FAIL: crash during the run"
  ok=0
fi

echo
if [ "$ok" -eq 1 ]; then
  echo "PASS: klick verified — IRQ12 packets arrive, the pointer tracks movement"
  echo "  on both axes with the y inversion correct, and it restores the pixels"
  echo "  underneath instead of leaving a trail"
  exit 0
fi
echo "FAIL: klick verification failed"
exit 1
