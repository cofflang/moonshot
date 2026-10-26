#!/usr/bin/env bash
#
# verify_crash.sh — prove that a CPU exception in a ring-3 program ends that
# program and nothing else.
#
# Starts test/crash.elf five times, each taking a different exception (divide
# by zero, a read of kernel memory, a read of an unmapped address, a
# non-canonical address, and running code from the heap), closing its window
# with alt+w after each. Checks
#   1. each fault is reported as a stopped task with the right vector
#      (0, 14, 14, 13, 14), and its address space is freed by the reaper. The
#      heap fault is an instruction fetch from a page that is there (error
#      code 21, present, user, fetch), at the address it jumped to
#   2. a program that makes the page runnable with protect() first runs the
#      same code, which returns 9
#   3. the system carries on, since a program (test/tickstest.elf)
#      started afterwards runs to completion and the shell still answers
#   4. no panic, no double fault
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

for kind in ["div", "null", "wild", "gp", "heap", "jit", "wcode", "rundata"]:
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
if [ "$vectors" != "0 14 14 13 14 14 14 " ]; then
  echo "FAIL: expected vectors 0 14 14 13 14 14 14 in that order, saw '$vectors'"
  ok=0
fi
# A program's code may be run and not written, its data written and not run.
codeline=$(grep 'stopped, exception vector=14' serial.log | sed -n 4p)
dataline=$(grep 'stopped, exception vector=14' serial.log | sed -n 5p)
if ! echo "$codeline" | grep -q 'errcode=7 '; then
  echo "FAIL: writing into the code was not a write to a present page: $codeline"; ok=0
fi
if ! echo "$dataline" | grep -q 'errcode=21 '; then
  echo "FAIL: running a string was not a fetch from a present page: $dataline"; ok=0
fi
heapline=$(grep 'stopped, exception vector=14' serial.log | sed -n 3p)
cr2=$(echo "$heapline" | sed -n 's/.* cr2=\([0-9]*\) .*/\1/p')
rip=$(echo "$heapline" | sed -n 's/.* rip=0x\([0-9a-fA-F]*\).*/\1/p')
if ! echo "$heapline" | grep -q 'errcode=21 ' || [ -z "$cr2" ] || [ -z "$rip" ] \
   || [ "$cr2" != "$((16#$rip))" ]; then
  echo "FAIL: the heap fault was not a fetch at the address jumped to: $heapline"
  ok=0
fi
if ! grep -q '^\[syscall\] exit code=9$' serial.log; then
  echo "FAIL: the code on the page made runnable did not return 9"
  ok=0
fi

freed=$(grep -c 'freed address space of task' serial.log || true)
echo "address spaces freed: $freed"
if [ "$freed" -lt 9 ]; then
  echo "FAIL: expected the five crashed programs, jit and tickstest to be reaped"
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
