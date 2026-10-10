#!/usr/bin/env bash
#
# test_disk_gap.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# A file inside a directory survives a reboot after something earlier in the
# node table was removed.
#
# jakel saves its node table slot by slot, and a node's parent is stored as a
# slot number. A loader that put the nodes it read into slots 0, 1, 2,
# ... one after another would leave no gap for a removed node, so every
# node after it would move down one slot while its parent number stayed the same.
# A file in a directory would then belong to the wrong parent after a reboot
# and could not be found. This exact sequence shows it.
#
# Boot one makes a.txt, then dir1 with c.txt in it, removes a.txt (the gap,
# in a slot before dir1's) and syncs. Boot two goes into dir1 and prints
# c.txt. The shell's `change` is used rather than a dir1/c.txt path because
# `write` and `echo --file` do not take paths with a directory in them.

set -u
cd "$(dirname "$0")"

./build.sh || exit 1

rm -f disk.img serial.log
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

isodir=isoroot
rm -rf "$isodir"
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1

sockfile=disk_gap.sock
qemu_pid=0
cleanup() { [ "$qemu_pid" -ne 0 ] && kill "$qemu_pid" 2>/dev/null; wait 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

boot() { # serial-log, then one shell command per argument
  local log=$1
  shift
  rm -f "$sockfile"
  qemu-system-x86_64 -cdrom moonshot.iso \
    -serial file:"$log" -display none -no-reboot -m 128 \
    -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
    -monitor unix:"$sockfile",server,nowait &
  qemu_pid=$!
  sleep 3
  python3 - "$sockfile" "$@" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.3)
def keys(text):
    # Lower case only, since a bare capital is not a key name QEMU knows.
    for c in text:
        name = {" ": "spc", "\n": "ret", ".": "dot", "-": "minus"}.get(c, c)
        s.send(("sendkey %s\n" % name).encode())
        time.sleep(0.05)
keys("root\n"); time.sleep(1)
keys("\n"); time.sleep(1.2)
for cmd in sys.argv[2:]:
    keys(cmd + "\n")
    time.sleep(1.0)
time.sleep(1)
s.close()
EOF
  kill "$qemu_pid" 2>/dev/null
  wait "$qemu_pid" 2>/dev/null
  qemu_pid=0
}

boot serial_gap1.log "make a.txt" "make dir1" "change dir1" "make c.txt" \
  "write c.txt gapsurvived" "echo --file c.txt" "change .." "remove a.txt" "sync"
boot serial.log "change dir1" "echo --file c.txt"

ok=1
if grep -q '^\[echo\] gapsurvived' serial_gap1.log; then
  echo "PASS: boot one wrote dir1/c.txt"
else
  echo "FAIL: boot one could not write dir1/c.txt, so this test proves nothing"
  ok=0
fi
if grep -q '^\[jakel\] loaded ' serial.log; then
  echo "PASS: boot two loaded the disk ($(grep -o 'loaded [0-9]* nodes' serial.log))"
else
  echo "FAIL: boot two did not load the disk"
  ok=0
fi
if grep -q '^\[echo\] gapsurvived' serial.log; then
  echo "PASS: dir1/c.txt read back after the reboot, despite the gap before it"
else
  echo "FAIL: dir1/c.txt lost after the reboot"
  ok=0
fi
rm -f serial_gap1.log
[ "$ok" -eq 1 ] && exit 0
exit 1
