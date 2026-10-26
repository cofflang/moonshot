#!/usr/bin/env bash
#
# verify_autostart.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# The first login of a normal boot (grub.cfg, not the test boot every other
# script uses) opens hylla beside the shell (shell_autostart).
#
#   1. Nothing panics.
#   2. Exactly one task starts after the login, hylla gets a window, and
#      five seconds later it has not exited.
set -u
cd "$(dirname "$0")/.."

./build.sh || exit 1

mkdir -p out && cd out

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
if [ ! -f moonshot.iso ]; then
  echo "FAIL: grub-mkrescue did not produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

sockfile=verify_autostart.sock
rm -f serial.log "$sockfile"
dd if=/dev/zero of=autostart.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=autostart.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile" autostart.img; }
trap cleanup EXIT
sleep 4

python3 - "$sockfile" <<'PY'
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.3)
sock.recv(65536)
for k in ["r", "o", "o", "t", "ret", "ret"]:
    sock.sendall(("sendkey %s\n" % k).encode())
    time.sleep(0.15)
    sock.recv(65536)
time.sleep(6.0)
sock.close()
PY
sleep 0.5

ok=1
after=$(sed -n "/screen login username='root' uid=0 ok=1/,\$p" serial.log)
if [ -z "$after" ]; then echo "FAIL: root did not log in"; ok=0; fi
if grep -aq 'PANIC' serial.log; then
  echo "FAIL 1. the kernel panicked after the login"
  grep -a 'PANIC' serial.log
  ok=0
fi
tids=$(echo "$after" | grep -ao '^\[sched\] spawned task [0-9]*' | grep -o '[0-9]*$' | tr '\n' ' ')
echo "tasks started after the login: $tids"
[ "$(echo $tids | wc -w)" -eq 1 ] || { echo "FAIL 2. expected one task after the login"; ok=0; }
echo "$after" | grep -aq '^\[elf\] windowed spawn wid=' || { echo "FAIL 2. hylla got no window"; ok=0; }
for t in $tids; do
  if echo "$after" | grep -aq "^\[sched\] task $t exited"; then
    echo "FAIL 2. task $t exited"; ok=0
  fi
done
if [ "$ok" -eq 1 ]; then
  echo "PASS: the first login opens hylla, and it keeps running"
  exit 0
fi
grep -aE '^\[(sched|elf|raket|spawnelf)\]' serial.log | tail -15
exit 1
