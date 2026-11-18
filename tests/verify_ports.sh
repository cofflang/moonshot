#!/usr/bin/env bash
#
# verify_ports.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that a ring-3 program reaches no I/O port. The TSS carries no I/O
# permission bitmap (boot.s puts its base past the TSS limit), and user code
# runs with IOPL 0, so every IN and OUT from ring 3 is a protection fault.
#
# Starts test/crash.elf with each of its port kinds, which run hand-built
# port I/O since coff refuses inb and outb in ring 3. Port 0x70 is the case
# that matters most, then the keyboard controller status at 0x64, the disk
# error register at 0x1F1 and the disk alternate status at 0x3F6, all reads,
# and a write of a zero to port 0x80. No kind changes a device, so a run on a
# kernel that lets them through does no harm. Checks
#   1. each kind is stopped with vector 13 and error code 0, in order, and
#      never exits with the 256 plus byte (read) or 512 (write) that would
#      mean the instruction went through
#   2. the faulting address is the IN or OUT itself, 6 bytes into a page
#   3. the system carries on, since test/tickstest.elf runs to completion
#      afterwards and the shell still answers
#   4. no panic, no double fault
set -u
cd "$(dirname "$0")/.."

./build.sh || exit 1

mkdir -p out && cd out

isodir=isoroot_ports
rm -rf "$isodir" ports.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o ports.iso "$isodir" >grub-mkrescue-ports.log 2>&1
if [ ! -f ports.iso ]; then
  echo "FAIL: grub-mkrescue did not produce ports.iso"
  cat grub-mkrescue-ports.log
  exit 1
fi

log=serial_ports.log
rm -f "$log" verify_ports.sock ports_disk.img
dd if=/dev/zero of=ports_disk.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom ports.iso \
  -serial file:"$log" -display none -no-reboot -m 128 \
  -drive file=ports_disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:verify_ports.sock,server,nowait &
qemu_pid=$!
cleanup() {
  kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null
  rm -rf verify_ports.sock ports_disk.img "$isodir"
}
trap cleanup EXIT

sleep 2

python3 - <<'PY'
import socket, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("verify_ports.sock")
time.sleep(0.2)
sock.recv(4096)

def send(cmd, settle=0.05):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    sock.recv(4096)

def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

def line(s):
    keymap = {".": "dot", " ": "spc", "/": "slash"}
    typ([keymap.get(c, c) for c in s] + ["ret"])

line("root")
time.sleep(0.5)
typ(["ret"])
time.sleep(1.0)

for kind in ["port", "kbdport", "diskport", "highport", "postport"]:
    line("start test/crash.elf " + kind)
    time.sleep(1.5)
    send("sendkey alt-w")
    time.sleep(0.5)

line("start test/tickstest.elf")
time.sleep(2.5)
send("sendkey alt-w")
time.sleep(0.5)
line("where")
time.sleep(0.5)
sock.close()
PY

sleep 1

ok=1

echo "--- port kinds, in order ---"
events=$(grep -E 'stopped, exception vector=|^\[syscall\] exit code=' "$log" | head -5)
echo "$events"
kinds=(port kbdport diskport highport postport)
i=0
while IFS= read -r ev; do
  kind=${kinds[$i]:-extra}
  if echo "$ev" | grep -q 'exit code='; then
    code=$(echo "$ev" | sed 's/.*code=//')
    echo "FAIL: $kind went through, exit code $code"
    ok=0
  elif ! echo "$ev" | grep -q 'vector=13 errcode=0 '; then
    echo "FAIL: $kind did not stop with vector 13 and error code 0: $ev"
    ok=0
  else
    rip=$(echo "$ev" | sed -n 's/.* rip=0x\([0-9a-fA-F]*\).*/\1/p')
    if [ -z "$rip" ] || [ $(( 16#$rip & 4095 )) -ne 6 ]; then
      echo "FAIL: $kind did not fault at the IN or OUT: $ev"
      ok=0
    fi
  fi
  i=$((i + 1))
done <<< "$events"
if [ "$i" -ne 5 ]; then
  echo "FAIL: expected 5 port results, saw $i"
  ok=0
fi

if ! grep -q 'ticks test ok' "$log"; then
  echo "FAIL: tickstest did not run after the port faults"
  ok=0
fi

if ! grep -q '\[sh\] /' "$log"; then
  echo "FAIL: the shell did not answer 'where' after the port faults"
  ok=0
fi

panic=$(grep -c 'PANIC' "$log" || true)
doublefault=$(grep -c 'double fault' "$log" || true)
echo "panics: $panic, double faults: $doublefault"
if [ "$panic" -gt 0 ] || [ "$doublefault" -gt 0 ]; then
  echo "FAIL: the kernel went down"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: ring-3 IN and OUT are stopped with vector 13"
  exit 0
else
  echo "--- serial log tail ---"
  grep -v '^tick' "$log" | tail -40
  exit 1
fi
