#!/usr/bin/env bash
#
# verify_form_tools.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# form's scale and mirror (programs/form/form.c0). A new tools.form starts
# as one cube, two units across. Tab picks its x low side, = makes that side
# a quarter bigger around its middle, and m adds a mirror image of it at x
# high. F2 saves, and test/et27.elf reads the file back.
#
#   1. The model has the cube's 12 faces and 8 corners and the mirrored
#      side's 2 faces and 4 corners.
#   2. The two new faces are the side's mirrored, corner by corner, in the
#      other order, so they face outwards.
#   3. The scaled side reaches 1.25 units out, 20 sixteenths.
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

sockfile=verify_form_tools.sock
rm -f serial.log "$sockfile" tools_*.ppm
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
sock.setblocking(False)
time.sleep(0.3)
def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    try:
        sock.recv(65536)
    except BlockingIOError:
        pass
def typ(keys, gap=0.1):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)
def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("start form.elf tools.form"); typ(["ret"]); time.sleep(3.5)
typ(["alt-tab"]); time.sleep(0.5)
typ(["tab"]); time.sleep(0.5)
typ(["equal"]); time.sleep(0.8)
typ(["m"]); time.sleep(0.8)
send("screendump tools_shot.ppm", settle=1.0)
typ(["f2"]); time.sleep(0.8)
typ(["alt-w"]); time.sleep(1.5)
word("start test/et27.elf"); typ(["ret"]); time.sleep(2.0)
word("echo end"); typ(["ret"]); time.sleep(0.4)
sock.close()
PY
sleep 0.5

ok=1
code=$(grep -ao 'exit code=[0-9]*' serial.log | tail -1 | sed 's/.*=//')
case "$code" in
  120) echo "  ok   the side was scaled to 20 sixteenths and mirrored, faces turned outwards" ;;
  1)   echo "  FAIL 1. the model does not have 14 faces"; ok=0 ;;
  2)   echo "  FAIL 1. the model does not have 12 corners"; ok=0 ;;
  3)   echo "  FAIL 2. the new faces are not the side mirrored, in the other order"; ok=0 ;;
  *)   echo "  FAIL 3. et27 gave $code, not 120 (116 is a side that was not scaled)"; ok=0 ;;
esac
if grep -aq PANIC serial.log; then echo "  FAIL: kernel panic"; ok=0; fi
if [ "$ok" -eq 1 ]; then echo "PASS: form scales what is picked and mirrors it across x = 0"; exit 0; fi
exit 1
