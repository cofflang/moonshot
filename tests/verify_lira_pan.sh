#!/usr/bin/env bash
#
# verify_lira_pan.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# lira's pan, mute and solo, by listening. tests/elf/20_pan_song.c0 writes
# test/pan.not, A4 on the square panned hard left and E5 on the triangle
# panned hard right, sounding together. lira opens it and plays it on a loop,
# QEMU's wav audiodev records the card, and the recording goes through three
# stretches of at least a second each, in this order
#   1. both sides, 440 Hz on the left and 659 Hz on the right
#   2. after 2 then m, which mutes the triangle, only the left
#   3. after m then o, which solos the triangle, only the right
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

rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

wav=lira_pan.wav
sockfile=verify_lira_pan.sock
rm -f serial.log "$sockfile" "$wav"
qemu-system-x86_64 -cdrom moonshot.iso \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -audiodev wav,id=snd0,path="$wav" -device sb16,audiodev=snd0 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

sleep 3

python3 - "$sockfile" <<'PY'
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.2)
sock.recv(65536)
def send(cmd, settle=0.05):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    sock.recv(65536)
def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)
def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.5)
word("start test/et20.elf"); typ(["ret"]); time.sleep(2.0)
word("start lira.elf test/pan.not"); typ(["ret"]); time.sleep(3.0)
typ(["alt-tab"]); time.sleep(0.8)
typ(["l", "spc"]); time.sleep(3.0)
typ(["2", "m"]); time.sleep(3.0)
typ(["m", "o"]); time.sleep(3.0)
typ(["spc"]); time.sleep(1.0)
sock.close()
PY

cleanup
trap - EXIT

ok=1
if ! grep -q '^\[syscall\] exit code=3$' serial.log; then
  echo "FAIL: 20_pan_song.c0 did not write the song (exit code 3)"
  ok=0
fi

python3 - "$wav" <<'PY' || ok=0
import sys, struct
data = open(sys.argv[1], "rb").read()
if data[0:4] != b"RIFF" or data[12:16] != b"fmt " or data[36:40] != b"data":
    print("FAIL: not the 44-byte wav header QEMU writes")
    sys.exit(1)
ch, rate = struct.unpack("<HI", data[22:28])
if ch != 2:
    print("FAIL: the recording has %d channel(s), not 2" % ch)
    sys.exit(1)
raw = data[44:]
raw = raw[:len(raw) - len(raw) % 4]
vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
left, right = vals[0::2], vals[1::2]
win = rate // 10

def kind(i):
    l = max(abs(v) for v in left[i:i + win])
    r = max(abs(v) for v in right[i:i + win])
    return ("L" if l > 2000 else "-") + ("R" if r > 2000 else "-")

kinds = [kind(i) for i in range(0, len(left) - win, win)]
runs = []
for k in kinds:
    if runs and runs[-1][0] == k:
        runs[-1][1] += 1
    else:
        runs.append([k, 1])
long_runs = [(k, n) for k, n in runs if n >= 10 and k != "--"]
print("stretches of 0.1 s: %s" % " ".join("%s x%d" % (k, n) for k, n in runs if k != "--"))
order = [k for k, n in long_runs]
if order[:3] != ["LR", "L-", "-R"]:
    print("FAIL: expected both sides, then the left alone, then the right alone, a second "
          "or more each, heard %s" % order)
    sys.exit(1)

def freq(side, a, b):
    xs = [i for i in range(a + 1, b) if (side[i - 1] >= 0) != (side[i] >= 0)]
    return (len(xs) - 1) / 2 / ((xs[-1] - xs[0]) / rate) if len(xs) > 2 else 0

first = next(i for i, k in enumerate(kinds) if k == "LR")
a, b = (first + 2) * win, (first + 8) * win
fl, fr = freq(left, a, b), freq(right, a, b)
print("while both play, left %.1f Hz, right %.1f Hz" % (fl, fr))
if not (432 <= fl <= 448 and 645 <= fr <= 672):
    print("FAIL: the sides are not A4 on the left and E5 on the right")
    sys.exit(1)
print("PASS: pan, mute and solo each heard where they belong")
PY

if grep -q 'PANIC' serial.log; then echo "FAIL: kernel panic"; ok=0; fi
if [ "$ok" -eq 1 ]; then
  echo "PASS: lira pans, mutes and solos"
  exit 0
fi
exit 1
