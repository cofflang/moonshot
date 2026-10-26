#!/usr/bin/env bash
#
# verify_spawn_kill.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# A program stopped before it ever ran. spawn_program leaves the new task a
# record of what to run, its file read into the kernel heap among it, and
# the task takes it when it first runs. A script, test/killrace.sk (written
# by test/et22.elf), starts mouse.elf and kills it on the next line twenty
# times, quicker than a timer tick, so most of those tasks never run and
# the reaper has to free what they never took (spawn_slot_drop).
#
#   1. Most of the reaped tasks never ran, they had no address space of
#      their own to free, so the path was taken.
#   2. The kernel heap is the same after the script as before it, measured
#      the same way both times, a mouse.elf started, run and killed, and
#      after a first script has made the interpreter's arena.
#   3. A file that starts like an ELF and is not one (test/broken.elf,
#      written by test/et26.elf) is refused by the loader, and its task
#      exits there, rather than returning from its entry point into
#      whatever lies past its stack, and the shell carries on.
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

sockfile=verify_spawn_kill.sock
rm -f serial.log "$sockfile"
dd if=/dev/zero of=spawn_kill.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=spawn_kill.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile" spawn_kill.img; }
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
def line(s, wait):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    for c in s:
        send("sendkey " + keymap.get(c, c))
        time.sleep(0.05)
    send("sendkey ret")
    time.sleep(wait)
def round_trip():
    line("start test/mouse.elf", 2.0)
    for t in (0, 1, 2, 3, 5, 6, 7):
        line("kill %d" % t, 0.3)
    time.sleep(1.0)
line("root", 0.5)
line("", 1.2)
line("start test/et22.elf", 2.0)
# The first script makes the interpreter's arena, kept from then on, so one
# runs before the heap is first measured.
line("run test/count.sk", 1.0)
round_trip()
line("echo before", 0.4)
line("run test/killrace.sk", 4.0)
line("echo after", 0.4)
round_trip()
line("start test/et26.elf", 2.0)
line("start test/broken.elf", 2.0)
line("echo still here", 0.6)
sock.close()
PY
sleep 0.5

ok=1
heaps=$(grep -ao '^\[sched\] freed address space of task .* kheap=[0-9]*' serial.log | grep -o '[0-9]*$' | tr '\n' ' ')
echo "kheap at each freed address space: $heaps"
# The last measure before the script, and the last of all.
a=$(sed -n '1,/^\[sh\] before$/p' serial.log | grep -ao 'kheap=[0-9]*' | tail -1 | grep -o '[0-9]*')
b=$(echo $heaps | awk '{print $NF}')
during=$(sed -n '/^\[sh\] before$/,/^\[sh\] after$/p' serial.log)
reaped=$(echo "$during" | grep -ac '^\[sched\] reaped task')
freed=$(echo "$during" | grep -ac '^\[sched\] freed address space')
echo "during the script: $reaped tasks reaped, $freed of them had run"
grep -aq '^\[sh\] killrace done$' serial.log || { echo "FAIL: the script did not finish"; ok=0; }
if [ $((reaped - freed)) -lt 10 ]; then
  echo "FAIL 1. fewer than 10 tasks were stopped before they ran, the path was not taken"; ok=0
fi
if [ -z "$a" ] || [ -z "$b" ] || [ "$b" -gt $((a + 512)) ]; then
  echo "FAIL 2. the kernel heap went from ${a:-?} to ${b:-?} across the script"; ok=0
else
  echo "  ok   2. the kernel heap went from $a to $b across the script"
fi
after_bad=$(sed -n '/^\[elf\] invalid ELF64 image$/,$p' serial.log)
if [ -n "$after_bad" ] && echo "$after_bad" | grep -aq '^\[sched\] task [0-9]* exited$' \
   && grep -aq '^\[sh\] still here$' serial.log; then
  echo "  ok   3. broken.elf was refused, its task exited, and the shell answered after it"
else
  echo "FAIL 3. broken.elf was not refused, its task did not exit, or the shell did not answer"; ok=0
fi
if grep -aq PANIC serial.log; then echo "FAIL: kernel panic"; grep -a PANIC serial.log; ok=0; fi
if [ "$ok" -eq 1 ]; then
  echo "PASS: programs stopped before they ran leave nothing behind, and a broken ELF ends only its own task"
  exit 0
fi
exit 1
