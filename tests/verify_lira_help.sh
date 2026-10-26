#!/usr/bin/env bash
#
# verify_lira_help.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# lira's help, the key list it draws over the grid.
#
#   1. h draws it, a box of the panel colour in the middle of lira's tile,
#      where before there was only grid.
#   2. Esc closes the help and leaves lira running, so the grid is back and
#      no task has exited.
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

sockfile=verify_lira_help.sock
rm -f serial.log "$sockfile" lhelp_*.ppm
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'EOF2'
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.3)
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
    keymap = {".": "dot", " ": "spc"}
    typ([keymap.get(c, c) for c in s])
def shot(name):
    send("screendump %s" % name, settle=0.8)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("start lira.elf"); typ(["ret"]); time.sleep(3.0)
typ(["alt-tab"]); time.sleep(1.0)
shot("lhelp_grid.ppm")
typ(["h"]); time.sleep(1.0)
shot("lhelp_open.ppm")
typ(["esc"]); time.sleep(1.0)
shot("lhelp_closed.ppm")
sock.close()
EOF2
sleep 1

python3 - <<'PY'
import sys
def load(path):
    data = open(path, "rb").read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace(): pos += 1
        start = pos
        while not data[pos:pos+1].isspace(): pos += 1
        fields.append(int(data[start:pos]))
    return fields[0], fields[1], data[pos+1:]
PANEL = bytes((0x18, 0x18, 0x1c))   # lira's COL_PANEL
def panel_in_middle(path):
    w, h, buf = load(path)
    # lira's tile is the right half. Its middle third, both ways.
    n = 0
    for y in range(h // 3, 2 * h // 3):
        for x in range(w // 2 + w // 6, w - w // 6):
            i = (y * w + x) * 3
            if buf[i:i+3] == PANEL: n += 1
    return n
grid, opened, closed = (panel_in_middle(p) for p in ("lhelp_grid.ppm", "lhelp_open.ppm", "lhelp_closed.ppm"))
print("panel-coloured pixels in the middle of lira's tile: grid %d, help %d, closed %d" % (grid, opened, closed))
ok = True
if opened - grid < 20000:
    print("FAIL  h did not draw the help over the grid"); ok = False
else:
    print("ok    h draws the help over the grid")
if closed != grid:
    print("FAIL  Esc did not bring the grid back"); ok = False
else:
    print("ok    Esc brings the grid back")
open("lhelp.result", "w").write("PASS\n" if ok else "FAIL\n")
PY

if grep -aq "^\[syscall\] exit code" serial.log; then
  echo "FAIL  Esc on the help quit lira"
  echo FAIL > lhelp.result
else
  echo "ok    lira is still running"
fi

if [ "$(cat lhelp.result)" = PASS ]; then
  echo "PASS: lira's help opens with h and Esc closes it without quitting"
  exit 0
fi
exit 1
