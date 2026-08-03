#!/usr/bin/env bash
#
# test_disk.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Proves jakel persistence across reboots.
#
# Phase 1 boots the kernel, creates a file, syncs it to disk, and
# shuts down. Phase 2 reboots against the SAME disk.img and verifies
# the file is still there and its content survived.
#
# Two independent passes: if the first-boot sync didn't actually write
# anything, phase 2 has nothing to load and the test fails.
set -u
cd "$(dirname "$0")"

cleanup() {
  rm -f disk_test.sock
}
trap cleanup EXIT

./build.sh || exit 1

# ------ Phase 1: write boot ------
rm -f disk.img serial.log
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

isodir=isoroot
rm -rf "$isodir"
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1

# Boot, create a file, write to it, sync to disk.
rm -f disk_test.sock
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:disk_test.sock,server,nowait &

QEMU_PID=$!
sleep 2

# Wait for the shell prompt to appear (boot sequence is fast).
# Run commands: make test.txt, write test.txt HelloDisk, sync
sendkey() {
  python3 -c "
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('disk_test.sock')
time.sleep(0.3)
for c in '$1':
    name = {
        ' ': 'spc', '\n': 'ret', '/': 'slash', '.': 'dot', '-': 'minus',
        'A': 'shift-a', 'B': 'shift-b', 'C': 'shift-c', 'D': 'shift-d',
        'E': 'shift-e', 'F': 'shift-f', 'G': 'shift-g', 'H': 'shift-h',
        'I': 'shift-i', 'J': 'shift-j', 'K': 'shift-k', 'L': 'shift-l',
        'M': 'shift-m', 'N': 'shift-n', 'O': 'shift-o', 'P': 'shift-p',
        'Q': 'shift-q', 'R': 'shift-r', 'S': 'shift-s', 'T': 'shift-t',
        'U': 'shift-u', 'V': 'shift-v', 'W': 'shift-w', 'X': 'shift-x',
        'Y': 'shift-y', 'Z': 'shift-z',
    }.get(c, c)
    s.send(f'sendkey {name}\n'.encode())
    time.sleep(0.03)
time.sleep(0.4)
" 2>/dev/null
}

# make test.txt
sendkey "make test.txt"
sendkey "\n"
sleep 1

# write test.txt HelloDisk
sendkey "write test.txt HelloDisk"
sendkey "\n"
sleep 1

# sync
sendkey "sync"
sendkey "\n"
sleep 2

# Shut down QEMU
echo "quit" | python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('disk_test.sock')
time.sleep(0.5)
s.send(b'quit\n')
time.sleep(1)
" 2>/dev/null
wait $QEMU_PID 2>/dev/null || true

# Verify phase 1: sync logged
if ! grep -qE '^\[jakel\] synced ' serial.log; then
  echo "FAIL (phase 1): [jakel] synced not found in serial output"
  echo "--- serial.log ---"
  cat serial.log
  exit 1
fi

# ------ Phase 2: read boot ------
# Use the SAME disk.img (still has the synced data).
rm -f serial.log

qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:disk_test.sock,server,nowait &

QEMU_PID=$!
sleep 2

# Send: echo --file test.txt
sendkey "echo --file test.txt"
sendkey "\n"
sleep 1

echo "quit" | python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('disk_test.sock')
time.sleep(0.5)
s.send(b'quit\n')
time.sleep(1)
" 2>/dev/null
wait $QEMU_PID 2>/dev/null || true

# Verify phase 2: loaded from disk AND file content survived
if ! grep -qE '^\[jakel\] loaded ' serial.log; then
  echo "FAIL (phase 2): [jakel] loaded not found -- sync didn't persist"
  echo "--- serial.log ---"
  cat serial.log
  exit 1
fi

if ! grep -q 'HelloDisk' serial.log; then
  echo "FAIL (phase 2): 'HelloDisk' not found in serial output -- file content lost"
  echo "--- serial.log ---"
  cat serial.log
  exit 1
fi

echo "PASS: disk persistence proven across two boots -- file written, synced, survived reboot, read back intact"
exit 0
