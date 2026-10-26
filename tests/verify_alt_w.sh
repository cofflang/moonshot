#!/usr/bin/env bash
#
# verify_alt_w.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Alt+W on a program that asked for it as a key (close_key).
#
#   1. skrift with unsaved text is asked, not stopped, so its window stays,
#      and F2 then saves and closes it, so the shell reads the text back.
#   2. skrift with nothing unsaved closes on Alt+W straight away.
#   3. A program that asked for the key but never reads it (crash.elf deaf)
#      is stopped by the second Alt+W, a second and more after the first.
#   4. skrift with unsaved text, asked, takes a second Alt+W as quit
#      without saving. It exits itself and the file is never written.
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

sockfile=verify_alt_w.sock
rm -f serial.log "$sockfile" altw_*.ppm
rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'PY'
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.3)
sock.recv(65536)
def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    sock.recv(65536)
def typ(keys, gap=0.08):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)
def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])
def mark(s):
    word("echo " + s); typ(["ret"]); time.sleep(0.5)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("edit a.txt"); typ(["ret"]); time.sleep(3.0)
word("kept"); typ(["alt-w"]); time.sleep(1.0)
typ(["f2"]); time.sleep(1.5)
mark("one")
word("echo --file a.txt"); typ(["ret"]); time.sleep(0.8)
word("edit b.txt"); typ(["ret"]); time.sleep(3.0)
typ(["alt-w"]); time.sleep(1.5)
mark("two")
word("start test/crash.elf deaf"); typ(["ret"]); time.sleep(2.0)
typ(["alt-tab"]); time.sleep(0.5)
typ(["alt-w"]); time.sleep(1.8)
typ(["alt-w"]); time.sleep(1.0)
mark("three")
word("edit c.txt"); typ(["ret"]); time.sleep(3.0)
word("lost"); typ(["alt-w"]); time.sleep(1.0)
typ(["alt-w"]); time.sleep(1.5)
word("echo --file c.txt"); typ(["ret"]); time.sleep(0.8)
mark("four")
sock.close()
PY
sleep 1

ok=1
log=$(grep -aE '^\[sh\] (one|two|three|four|kept|lost)$|alt\+w asks|\[tavla\] closed|exit code' serial.log)
echo "$log"
# Between start and "one" there is one request, no window closed by kakel, the
# editor exited itself, and then the file holds the text.
first=$(echo "$log" | sed -n '1,/^\[sh\] one$/p')
if ! echo "$first" | grep -q 'alt+w asks' || echo "$first" | grep -q 'tavla\] closed'; then
  echo "FAIL: Alt+W stopped skrift with unsaved text instead of asking"; ok=0
fi
if ! grep -aq '^\[sh\] kept$' serial.log; then
  echo "FAIL: F2 after Alt+W did not save the text"; ok=0
fi
second=$(echo "$log" | sed -n '/^\[sh\] one$/,/^\[sh\] two$/p')
if ! echo "$second" | grep -q 'exit code=0' || echo "$second" | grep -q 'tavla\] closed'; then
  echo "FAIL: Alt+W on unchanged skrift did not close it straight away"; ok=0
fi
third=$(echo "$log" | sed -n '/^\[sh\] two$/,/^\[sh\] three$/p')
if [ "$(echo "$third" | grep -c 'alt+w asks')" != "1" ] || ! echo "$third" | grep -q 'tavla\] closed'; then
  echo "FAIL: the program that does not read the key was not stopped by the second Alt+W"; ok=0
fi
fourth=$(echo "$log" | sed -n '/^\[sh\] three$/,/^\[sh\] four$/p')
if [ "$(echo "$fourth" | grep -c 'alt+w asks')" != "2" ] || ! echo "$fourth" | grep -q 'exit code=0' \
   || echo "$fourth" | grep -q 'tavla\] closed' || echo "$fourth" | grep -q '^\[sh\] lost$'; then
  echo "FAIL: a second Alt+W at skrift's question did not quit it without saving"; ok=0
fi
if [ "$ok" -eq 1 ]; then
  echo "PASS: Alt+W asks a program that listens, a second one discards, and it stops one that does not"
  exit 0
fi
exit 1
