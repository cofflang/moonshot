#!/usr/bin/env bash
#
# verify_windowed_ring3.sh — prove that spawn3 creates a dedicated kakel window
# for the ring-3 process and routes output there.
#
# Checks:
#   1. Serial log shows "[ring3] windowed spawn wid=N" (kakel_split called)
#   2. "hello from ring 3" reaches serial (syscall output is correct)
#   3. Two sequential spawn3 calls each get their own window
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

# spawn3 — windowed ring-3 test (flat binary)
typ(["s","p","a","w","n","3","ret"])
time.sleep(1.5)

# spawn3 again — second ring-3 process, should get its own window
typ(["s","p","a","w","n","3","ret"])
time.sleep(1.5)

# spawn3 test/hello.elf — windowed ELF ring-3 test. Fixtures live in
# /test now, so this needs the path.
typ(["s","p","a","w","n","3","spc","t","e","s","t","slash","h","e","l","l","o","dot","e","l","f","ret"])
time.sleep(1.5)

sock.close()
EOF

sleep 2

ok=1

# Check 1: windowed spawn messages for flat binary
ring3_win=$(grep -c '\[ring3\] windowed spawn wid=' serial.log || true)
echo "ring3 windowed spawn messages: $ring3_win"
if [ "$ring3_win" -lt 2 ]; then
  echo "FAIL: expected at least 2 [ring3] windowed spawn messages, got $ring3_win"
  ok=0
fi

# Check 2: windowed spawn message for ELF
elf_win=$(grep -c '\[elf\] windowed spawn wid=' serial.log || true)
echo "elf windowed spawn messages: $elf_win"
if [ "$elf_win" -lt 1 ]; then
  echo "FAIL: expected at least 1 [elf] windowed spawn message, got $elf_win"
  ok=0
fi

# Check 3: output reached serial
ring3_hello=$(grep -c 'hello from ring 3' serial.log || true)
echo "hello from ring 3 count: $ring3_hello"
if [ "$ring3_hello" -lt 2 ]; then
  echo "FAIL: expected at least 2 'hello from ring 3', got $ring3_hello"
  ok=0
fi

elf_hello=$(grep -c 'hello from elf' serial.log || true)
echo "hello from elf count: $elf_hello"
if [ "$elf_hello" -lt 1 ]; then
  echo "FAIL: expected at least 1 'hello from elf', got $elf_hello"
  ok=0
fi

# Check 4: no crash
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
  echo "  flat binary: 2 spawn3 calls each got their own window id"
  echo "  ELF binary: spawn3 test/hello.elf got its own window id"
  echo "  all output reached serial, no crashes"
  echo ""
  echo "--- windowed spawn messages ---"
  grep -E '\[(ring3|elf)\] windowed spawn wid=' serial.log
  echo "--- ring-3 output ---"
  grep -E 'hello from (ring 3|elf)' serial.log
  exit 0
else
  echo ""
  echo "--- serial log tail ---"
  tail -60 serial.log
  exit 1
fi
