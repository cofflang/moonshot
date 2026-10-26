#!/usr/bin/env bash
#
# verify_form.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# form, the 3D modeller, on djup. A new model is one cube, 8 corners and 12
# faces. The arrows turn the camera half way round, Tab picks the cube's
# first side, now facing the camera, e pulls it out (4 corners and 8 faces
# more), 3 colours it yellow, Ctrl+Z takes the colour back and Ctrl+Y puts it
# back, F2 saves and Alt+W quits.
#
#   1. The file is 48 + 12 * 24 + 20 * 32 = 976 bytes, the pulled-out cube.
#   2. Its two yellow faces (0xe8d04a), counted by test/et24.elf, are the
#      picked side.
#   3. The window showed the yellow face, shaded.
set -u
cd "$(dirname "$0")/.."

./tools/gen_elf_tests.sh >/dev/null || exit 1
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

sockfile=verify_form.sock
rm -f serial.log "$sockfile" form_*.ppm
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
word("start form.elf ship.form"); typ(["ret"]); time.sleep(3.5)
typ(["alt-tab"]); time.sleep(0.5)
typ(["right"] * 16); time.sleep(0.5)
typ(["tab"]); time.sleep(0.5)
typ(["e"]); time.sleep(0.8)
typ(["3"]); time.sleep(0.8)
typ(["ctrl-z"]); time.sleep(0.8)
typ(["ctrl-y"]); time.sleep(0.8)
send("screendump form_shot.ppm", settle=1.0)
typ(["f2"]); time.sleep(0.8)
typ(["alt-w"]); time.sleep(1.5)
word("count ship.form"); typ(["ret"]); time.sleep(0.8)
word("start test/et24.elf"); typ(["ret"]); time.sleep(2.0)
sock.close()
PY
sleep 1
ok=1
if grep -aqE '^\[sh\] [0-9]+ lines?, [0-9]+ words?, 976 bytes' serial.log; then
  echo "  ok   1. the saved model has 12 corners and 20 faces"
else
  echo "  FAIL 1. the saved model is not 976 bytes: $(grep -aE '^\[sh\] [0-9]+ lines?, ' serial.log | tail -1)"; ok=0
fi
if grep -aq '^\[syscall\] exit code=2$' serial.log; then
  echo "  ok   2. the picked side, two triangles, was saved yellow"
else
  echo "  FAIL 2. et24 counted $(grep -ao 'exit code=[0-9]*' serial.log | tail -1) yellow faces, not 2"; ok=0
fi
python3 - <<'PY' || ok=0
from PIL import Image
im = Image.open("form_shot.ppm").convert("RGB")
# Yellow 0xe8d04a lit somewhere from 35% to 100%, the red and green well
# above the blue.
n = sum(1 for (r, g, b) in im.getdata() if r > 70 and g > 60 and r > 2 * b and g > 2 * b and abs(r - g) < r // 4)
print("  %s   3. the window shows the yellow face (%d pixels)" % ("ok" if n > 500 else "FAIL", n))
import sys; sys.exit(0 if n > 500 else 1)
PY
if [ "$ok" -eq 1 ]; then echo "PASS: form pulls out, colours, undoes, saves and shows a model"; exit 0; fi
exit 1
