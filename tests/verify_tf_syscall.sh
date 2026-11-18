#!/usr/bin/env bash
#
# verify_tf_syscall.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Runs a ring-3 program whose hand-built machine code sets TF with
# pushfq/popfq and then executes SYSCALL. The syscall must complete and
# print its diagnostic, then the resulting trap must stop only that program.
# Taking the trap in ring 0 and panicking is a failure.
# Then runs one that makes a syscall with its stack pointer at 0. The syscall
# runs, and the kernel stops the program instead of returning to a stack
# outside the user range, so it never reaches the ud2 after the syscall.
# Before those, NMIs are sent through the monitor at the shell and while a
# program makes syscalls in a loop, and neither may panic or stop it. Then a
# program sets DF, AC and NT and asks for IOPL 3 before a syscall. DF and AC
# must come back set and NT and IOPL clear. Ring 3 cannot raise IOPL, so
# iopl=0 holds with or without the return mask.
set -u
cd "$(dirname "$0")/.."

./build.sh || exit 1

mkdir -p out && cd out

isodir=isoroot-tf
rm -rf "$isodir" tf.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o tf.iso "$isodir" >grub-mkrescue-tf.log 2>&1
if [ ! -f tf.iso ]; then
  echo "FAIL: grub-mkrescue did not produce tf.iso"
  cat grub-mkrescue-tf.log
  exit 1
fi

rm -f tf-serial.log tf.sock
[ -f disk.img ] || dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

qemu-system-x86_64 -cdrom tf.iso \
  -serial file:tf-serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:tf.sock,server,nowait &
qemu_pid=$!
cleanup() {
  kill "$qemu_pid" 2>/dev/null
  wait "$qemu_pid" 2>/dev/null
  rm -f tf.sock
}
trap cleanup EXIT

sleep 2
python3 - <<'PY'
import socket, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("tf.sock")
time.sleep(0.2)
try:
    sock.recv(4096)
except BlockingIOError:
    pass

def send(cmd, settle=0.05):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    try:
        sock.recv(4096)
    except BlockingIOError:
        pass

def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

def line(s):
    keymap = {".": "dot", " ": "spc", "/": "slash"}
    typ([keymap.get(c, c) for c in s] + ["ret"])

def nmis(count, gap):
    for _ in range(count):
        send("nmi", 0)
        time.sleep(gap)

line("root")
time.sleep(0.5)
typ(["ret"])
time.sleep(1.0)
nmis(50, 0.02)
line("start test/crash.elf spin")
time.sleep(0.3)
nmis(80, 0.02)
time.sleep(1.5)
send("sendkey alt-w")
time.sleep(1.0)
line("start test/crash.elf flags")
time.sleep(3.0)
send("sendkey alt-w")
time.sleep(1.0)
line("start test/crash.elf tf")
time.sleep(3.0)
send("sendkey alt-w")
time.sleep(1.0)
line("start test/crash.elf badrsp")
time.sleep(3.0)
send("sendkey alt-w")
time.sleep(1.0)
line("where")
time.sleep(0.5)
sock.close()
PY

sleep 1

echo "--- tf syscall output ---"
grep -a "tf syscall ok" tf-serial.log || true
echo "--- stopped tasks ---"
grep -a "stopped, exception" tf-serial.log || true
echo "--- zero-stack syscall output ---"
grep -a "badrsp syscall ran" tf-serial.log || true
echo "--- nmi and flags output ---"
grep -a "spin ok\|flags " tf-serial.log || true
echo "--- panic lines ---"
grep -a "KERNEL PANIC" tf-serial.log || true

ok=1
if grep -qa "KERNEL PANIC" tf-serial.log; then
  echo "FAIL: kernel panicked"
  ok=0
fi
if ! grep -qa "tf syscall ok" tf-serial.log; then
  echo "FAIL: the SYSCALL did not complete (no debug print)"
  ok=0
fi
if ! grep -qa "stopped, exception vector=1 " tf-serial.log; then
  echo "FAIL: the trap did not stop the program as vector 1"
  ok=0
fi
if ! grep -qa "badrsp syscall ran" tf-serial.log; then
  echo "FAIL: the zero-stack SYSCALL did not run"
  ok=0
fi
if ! grep -qa "stopped, exception vector=13\$" tf-serial.log; then
  echo "FAIL: the zero-stack return was not refused"
  ok=0
fi
if grep -qa "stopped, exception vector=6 " tf-serial.log; then
  echo "FAIL: the kernel returned to the zero stack"
  ok=0
fi
if ! grep -qa "spin ok" tf-serial.log; then
  echo "FAIL: the syscall loop did not finish under NMIs"
  ok=0
fi
if grep -qa "exception vector=2 " tf-serial.log; then
  echo "FAIL: an NMI stopped a program"
  ok=0
fi
if ! grep -qa "flags df=1 ac=1 nt=0 iopl=0 tf=0" tf-serial.log; then
  echo "FAIL: the flags after SYSRET are not DF and AC alone"
  ok=0
fi
if [ "$ok" -eq 1 ]; then
  echo "PASS: TF SYSCALL completed and stopped only the program, zero-stack return refused, NMIs harmless, return flags clean"
  exit 0
fi
exit 1