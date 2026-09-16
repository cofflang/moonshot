#!/usr/bin/env bash
#
# verify_ticks.sh — prove that ticks() (SYS_TICKS) works end to end in a
# real ring-3 --elf program, not just at the compiler level.
#
# Checks:
#   1. "ticks test ok" reaches serial (the program ran the whole busy loop
#      without faulting)
#   2. "[syscall] exit code=1" (the program's own check that a second
#      ticks() read is strictly greater than the first -- proves the
#      counter is live and monotonic from ring 3, not just present)
#   3. No crash, no panic

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

rm -f serial.log verify_ticks.sock
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:verify_ticks.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }
trap cleanup EXIT

sleep 2

python3 - <<'EOF'
import socket, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("verify_ticks.sock")
time.sleep(0.2)
sock.recv(4096)  # discard QEMU monitor banner

def send(cmd):
    sock.sendall((cmd + "\n").encode())
    time.sleep(0.05)
    sock.recv(4096)

def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

# Login as root (raket gate)
typ(["r", "o", "o", "t", "ret"])
time.sleep(0.5)
typ(["ret"])  # empty password
time.sleep(1.0)

# spawn3 test/tickstest.elf -- fixtures live in /test now.
typ(["s","p","a","w","n","3","spc","t","e","s","t","slash","t","i","c","k","s","t","e","s","t","dot","e","l","f","ret"])
time.sleep(2.5)

sock.close()
EOF

sleep 2

ok=1

ok_msg=$(grep -c 'ticks test ok' serial.log || true)
echo "'ticks test ok' count: $ok_msg"
if [ "$ok_msg" -lt 1 ]; then
  echo "FAIL: expected 'ticks test ok' in serial output"
  ok=0
fi

exit_code=$(grep -c '\[syscall\] exit code=1$' serial.log || true)
echo "'[syscall] exit code=1' count: $exit_code"
if [ "$exit_code" -lt 1 ]; then
  echo "FAIL: expected exit code 1 (proves ticks() is live and monotonic)"
  ok=0
fi

panic=$(grep -c 'PANIC' serial.log || true)
doublefault=$(grep -c 'double fault' serial.log || true)
echo "panics: $panic, double faults: $doublefault"
if [ "$panic" -gt 0 ] || [ "$doublefault" -gt 0 ]; then
  echo "FAIL: crash detected"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: ticks() (SYS_TICKS) verified end to end in a real ring-3 --elf program"
  exit 0
else
  echo "--- serial.log tail ---"
  tail -40 serial.log
  exit 1
fi
