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
# script uses) opens hylla beside the shell, with fanfar playing the login
# audition behind it, without a tavla of its own (shell_autostart).
#
#   1. Nothing panics. Each task gets its own record of what to run
#      (spawn_rec_base), since with one set for both the second spawn would
#      overwrite the first's before it ran, and a task finding no image
#      would return from its entry point and double-fault the machine.
#   2. Exactly two tasks start after the login, hylla and fanfar. Exactly
#      one window opens, hylla's, and no spawn asks for one and finds no
#      room, so fanfar gets none. fanfar is quiet, printing to the serial
#      line only. hylla keeps running and fanfar finishes with exit code zero.
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
  -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
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
time.sleep(8.0)
sock.close()
PY
sleep 0.5

ok=1
python3 - <<'PYLOG'
import pathlib, re
p = pathlib.Path('serial.log')
s = p.read_text()
s = re.sub(r'\[sched\] -> task [^\n]*\n|\[elf\] loaded,[^\n]*\n', '', s)
pathlib.Path('autostart-normalized.log').write_text(s)
PYLOG
after=$(sed -n "/screen login username='root' uid=0 ok=1/,\$p" autostart-normalized.log)
if [ -z "$after" ]; then echo "FAIL: root did not log in"; ok=0; fi
if grep -aq 'PANIC' serial.log; then
  echo "FAIL 1. the kernel panicked after the login"
  grep -a 'PANIC' serial.log
  ok=0
fi
tids=$(echo "$after" | grep -ao '^\[sched\] spawned task [0-9]*' | grep -o '[0-9]*$' | tr '\n' ' ')
echo "tasks started after the login: $tids"
[ "$(echo $tids | wc -w)" -eq 2 ] || { echo "FAIL 2. expected two tasks after the login"; ok=0; }
wins=$(echo "$after" | grep -ac '^\[elf\] windowed spawn wid=')
echo "windows opened after the login: $wins"
[ "$wins" -eq 1 ] || { echo "FAIL 2. expected exactly one window after the login, hylla's"; ok=0; }
if echo "$after" | grep -aq '^\[elf\] no window available'; then
  echo "FAIL 2. a spawn after the login asked for a window and found no room"; ok=0
fi
chimes=$(echo "$after" | sed -n 's/^\[raket\] autostart fanfar task=\([0-9][0-9]*\) quiet=[0-9-]*$/\1/p')
echo "$after" | grep -aq '^\[raket\] autostart fanfar task=[0-9][0-9]* quiet=1$' || { echo "FAIL 2. fanfar is not quiet"; ok=0; }
if [ "$(echo "$chimes" | wc -w)" -ne 1 ]; then
  echo "FAIL 2. expected one fanfar autostart task"; ok=0
fi
case " $tids " in
  *" $chimes "*) ;;
  *) echo "FAIL 2. fanfar task was not spawned after login"; ok=0 ;;
esac
echo "$after" | grep -aq '^\[fanfar\] done$' || { echo "FAIL 2. fanfar did not finish"; ok=0; }
echo "$after" | grep -aq '^\[syscall\] exit code=0$' || { echo "FAIL 2. fanfar did not exit cleanly"; ok=0; }
if echo "$after" | grep -a '^\[syscall\] exit code=' | grep -avq '^\[syscall\] exit code=0$'; then
  echo "FAIL 2. nonzero program exit"; ok=0
fi
for t in $tids; do
  if [ "$t" = "$chimes" ]; then continue; fi
  if echo "$after" | grep -aq "^\[sched\] task $t exited"; then
    echo "FAIL 2. task $t exited"; ok=0
  fi
done
if [ "$ok" -eq 1 ]; then
  echo "PASS: the first login opens hylla, and fanfar plays without a window and exits cleanly"
  exit 0
fi
grep -aE '^\[(sched|elf|raket|spawnelf)\]' serial.log | tail -15
exit 1
