#!/usr/bin/env bash
#
# test_reclaim.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# A ring-3 program's memory comes back when it ends, its code, stack and
# heap pages and the page tables over them, not only its kernel stack.
#
#   1. utsikt, which allocates a frame buffer of several megabytes, is opened
#      and closed with alt+w twice, and a short program (test/alloctest.elf)
#      runs to its exit three times, as many as there are windows left for.
#      Every one of those deaths frees the task's address space, and the
#      reaper says how many pages.
#   2. utsikt's deaths give back at least 700 pages, its frame buffer.
#   3. pmm's high-water mark does not move between two runs of the same
#      program. A program that ends leaves its pages on pmm's free list and
#      the next run is built from them, so nothing new is taken from the
#      top. If the address space were not freed, every run would take more.
#   4. The kernel heap is as full after the second utsikt as after the first
#      (both windows closed), and each alloctest run adds less than its
#      4KB image (its finished window and title stay). A loader that kept
#      every image would stop loading anything after a few dozen starts.

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

sockfile=test_reclaim.sock
rm -f serial.log "$sockfile"
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
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])
def shot(name):
    send("screendump %s" % name, settle=0.8)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
# utsikt first, while there is room for its window. A finished alloctest
# leaves its window on screen, and a few of them fill the layout.
for _ in range(2):
    word("start utsikt.elf"); typ(["ret"]); time.sleep(4.0)
    typ(["alt-tab"]); time.sleep(1.0)
    send("sendkey alt-w", settle=0.5); time.sleep(2.0)
for _ in range(3):
    word("start test/alloctest.elf"); typ(["ret"]); time.sleep(2.5)
# The reaper never frees the task it runs on, and after the last exit no
# other task is runnable, so wake the shell to get that one reaped too.
typ(["ret"]); time.sleep(1.5)

sock.close()
EOF2
sleep 1

python3 - <<'PY'
import re, sys
log = open("serial.log", "rb").read().decode("utf-8", "replace")
log = re.sub(r"\[sched\] -> task \d+ \(counter=\d+\)\n", "", log)
log = re.sub(r"tick \d+\n", "", log)
found = re.findall(r"\[sched\] freed address space of task \d+, (\d+) pages, pmm top=(\d+) kheap=(\d+)", log)
rows = [(int(p), int(t)) for p, t, k in found]
kheap = [int(k) for p, t, k in found]
print("kernel heap used after each: %s" % kheap)
print("address spaces freed: %d, pages %s" % (len(rows), [p for p, t in rows]))
print("pmm top after each: %s" % sorted(set(t for p, t in rows)))
ok = True
if len(rows) < 5:
    print("FAIL: expected five ring-3 deaths to free their address spaces")
    ok = False
if any(p <= 0 for p, t in rows):
    print("FAIL: an address space gave nothing back")
    ok = False
if len(rows) >= 5:
    if rows[0][0] < 700 or rows[1][0] < 700:
        print("FAIL: utsikt's frame buffer did not come back")
        ok = False
    if rows[1][1] != rows[0][1] or len(set(t for p, t in rows[2:5])) > 1:
        print("FAIL: pmm kept taking new pages, so freed ones are not being reused")
        ok = False
if len(kheap) >= 5:
    if kheap[1] != kheap[0]:
        print("FAIL: the kernel heap grew between two utsikt runs")
        ok = False
    if any(b - a >= 4096 for a, b in zip(kheap[2:4], kheap[3:5])):
        print("FAIL: an alloctest run kept its image in the kernel heap")
        ok = False
panics = len(re.findall(r"PANIC|double fault", log))
if panics:
    print("FAIL: %d panics" % panics)
    ok = False
sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: ring-3 address spaces are freed and their pages reused"
  exit 0
fi
echo "FAIL: see above"
exit 1
