#!/usr/bin/env bash
#
# verify_crash.sh — prove that a CPU exception in a ring-3 program ends that
# program and nothing else.
#
# Starts test/crash.elf four times, each taking a different exception (divide
# by zero, a read of kernel memory, a read of an unmapped address, and a
# non-canonical address), closing its window with alt+w after each. Checks
#   1. each fault is reported as a stopped task with the right vector
#      (0, 14, 14, 13), and its address space is freed by the reaper
#   2. the system carries on, since a fifth program (test/tickstest.elf)
#      started afterwards runs to completion and the shell still answers
#   3. no panic, no double fault
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

rm -f serial.log verify_crash.sock crash_end.ppm
[ -f disk.img ] || dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:verify_crash.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f verify_crash.sock; }
trap cleanup EXIT

sleep 2

python3 - <<'PY'
import socket, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("verify_crash.sock")
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

for kind in ["div", "null", "wild", "gp"]:
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
send("screendump crash_end.ppm", settle=0.6)
sock.close()
PY

sleep 1

ok=1

echo "--- stopped tasks ---"
grep 'stopped, exception' serial.log || true
vectors=$(grep -o 'stopped, exception vector=[0-9]*' serial.log | sed 's/.*=//' | tr '\n' ' ')
if [ "$vectors" != "0 14 14 13 " ]; then
  echo "FAIL: expected vectors 0 14 14 13 in that order, saw '$vectors'"
  ok=0
fi

freed=$(grep -c 'freed address space of task' serial.log || true)
echo "address spaces freed: $freed"
if [ "$freed" -lt 5 ]; then
  echo "FAIL: expected the four crashed programs and tickstest to be reaped"
  ok=0
fi

if ! grep -q 'ticks test ok' serial.log; then
  echo "FAIL: tickstest did not run after the crashes"
  ok=0
fi

if ! grep -q '\[sh\] /' serial.log; then
  echo "FAIL: the shell did not answer 'where' after the crashes"
  ok=0
fi

panic=$(grep -c 'PANIC' serial.log || true)
doublefault=$(grep -c 'double fault' serial.log || true)
echo "panics: $panic, double faults: $doublefault"
if [ "$panic" -gt 0 ] || [ "$doublefault" -gt 0 ]; then
  echo "FAIL: the kernel went down"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: ring-3 faults end only the faulting program"
  exit 0
else
  echo "--- serial.log tail ---"
  grep -v '^tick' serial.log | tail -40
  exit 1
fi
