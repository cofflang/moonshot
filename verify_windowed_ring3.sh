#!/usr/bin/env bash
#
# verify_windowed_ring3.sh — prove that start creates a dedicated kakel window
# for the ring-3 process and routes output there.
#
# Checks
#   1. Serial log shows "[elf] windowed spawn wid=N" (kakel_split called)
#   2. "hello from elf" reaches serial (syscall output is correct)
#   3. Two sequential start calls each get their own window
#   4. No crash, no panic

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

rm -f serial.log verify_win.sock
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:verify_win.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }
trap cleanup EXIT

sleep 2

python3 - <<'EOF'
import socket, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("verify_win.sock")
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

# start test/hello.elf twice, each run should get its own window. Fixtures
# live in /test, so this needs the path.
hello = ["s","t","a","r","t","spc","t","e","s","t","slash","h","e","l","l","o","dot","e","l","f","ret"]
typ(hello)
time.sleep(1.5)
typ(hello)
time.sleep(1.5)

sock.close()
EOF

sleep 2

ok=1

# Check 1, one windowed spawn per start, in two different windows
elf_win=$(grep -c '\[elf\] windowed spawn wid=' serial.log || true)
elf_wids=$(grep -oE '\[elf\] windowed spawn wid=[0-9]+' serial.log | sort -u | wc -l)
echo "elf windowed spawn messages: $elf_win, distinct windows: $elf_wids"
if [ "$elf_win" -lt 2 ] || [ "$elf_wids" -lt 2 ]; then
  echo "FAIL: expected 2 [elf] windowed spawn messages in 2 windows"
  ok=0
fi

# Check 2, output reached serial
elf_hello=$(grep -c 'hello from elf' serial.log || true)
echo "hello from elf count: $elf_hello"
if [ "$elf_hello" -lt 2 ]; then
  echo "FAIL: expected at least 2 'hello from elf', got $elf_hello"
  ok=0
fi

# Check 4, no crash
panic=$(grep -c 'PANIC' serial.log || true)
doublefault=$(grep -c 'double fault' serial.log || true)
echo "panics: $panic, double faults: $doublefault"
if [ "$panic" -gt 0 ] || [ "$doublefault" -gt 0 ]; then
  echo "FAIL: crash detected"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo ""
  echo "PASS: windowed ring-3 spawn verified —"
  echo "  start test/hello.elf twice, each run got its own window id"
  echo "  all output reached serial, no crashes"
  echo ""
  echo "--- windowed spawn messages ---"
  grep -E '\[elf\] windowed spawn wid=' serial.log
  echo "--- ring-3 output ---"
  grep -E 'hello from elf' serial.log
  exit 0
else
  echo ""
  echo "--- serial log tail ---"
  tail -60 serial.log
  exit 1
fi
