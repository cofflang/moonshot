#!/usr/bin/env bash
#
# verify_shell_text.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# A shell window keeps its text when the layout around it changes. kakel
# keeps every shell window's characters (its grid) and draws them again,
# instead of a blank window and a fresh prompt.
#
#   1. A program starting beside the shell halves its width, and the lines
#      typed before are still there, pixel for pixel, with no second prompt.
#   2. Alt+M fills the screen with the shell, the same.
#   3. Alt+L locks the screen and the password opens it, the same.
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

sockfile=verify_shell_text.sock
rm -f serial.log "$sockfile" text_*.ppm
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
def typ(keys, gap=0.08):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)
def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])
def shot(name):
    send("screendump %s" % name, settle=1.0)
    data = open(name, "rb").read()
    head = data.split(b"\n", 3)
    w, h = map(int, head[1].split())
    return w, h, head[3]
def row(img, r, x1):
    w, h, d = img
    return b"".join(d[((r * 8 + y) * w) * 3:((r * 8 + y) * w + x1) * 3] for y in range(8))
def lit(img, r, x1):
    return any(b != 0 for b in row(img, r, x1))
fails = []
def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.5)
for line in ["echo the first line", "echo and a second one", "echo three"]:
    word(line); typ(["ret"]); time.sleep(0.6)
a = shot("text_a.ppm")
X = 480    # the left part, inside the shell however wide it is
rows = [r for r in range(0, 90) if lit(a, r, X)]
print("     text rows before: %s" % rows)
check(len(rows) >= 6, "the shell shows its lines")
last = max(rows)
def same(img):
    return all(row(img, r, X) == row(a, r, X) for r in range(0, last + 1)) and not lit(img, last + 1, X)

word("start hylla.elf"); typ(["ret"]); time.sleep(4.0)
b = shot("text_b.ppm")
# Everything above the line start was typed on stays as it was.
rows_b = [r for r in range(0, 90) if lit(b, r, X)]
print("     text rows after start: %s" % rows_b)
# start says which task it started, then one prompt follows.
check(all(row(b, r, X) == row(a, r, X) for r in range(0, last)) and max(rows_b) == last + 2,
      "1. a program starting beside it leaves the shell's lines, and one prompt")
last = max(rows_b)
a = b
typ(["alt-tab"]); time.sleep(0.5)
typ(["alt-tab"]); time.sleep(0.5)
typ(["alt-m"]); time.sleep(1.5)
check(same(shot("text_c.ppm")), "2. Alt+M keeps them")
typ(["alt-m"]); time.sleep(1.5)
typ(["alt-l"]); time.sleep(1.0)
typ(["ret"]); time.sleep(2.0)
check(same(shot("text_d.ppm")), "3. locking and unlocking keeps them")
sock.close()
open("text_steps.result", "w").write("FAIL\n" if fails else "PASS\n")
PY
sleep 1
ok=1
[ "$(cat text_steps.result 2>/dev/null)" = "PASS" ] || ok=0
rm -f text_steps.result
if [ "$ok" -eq 1 ]; then echo "PASS: shell windows keep their text through relayouts"; exit 0; fi
exit 1
