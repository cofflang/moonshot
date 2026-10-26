#!/usr/bin/env bash
#
# verify_oljud_stereo.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# oljud plays the 16-bit formats a program picks with sound_format().
# tests/elf/19_stereo.c0 plays half a second of 441 Hz on the left only, half
# a second of 882 Hz on the right only, then half a second of 441 Hz as
# 16-bit mono, with gaps between. QEMU's wav audiodev records the card, and
#   1. the program's own checks all hold (exit code 7)
#   2. the first tone is on the left at 441 Hz with the right silent
#   3. the second is on the right at 882 Hz with the left silent
#   4. the third is on both sides, the same, at 441 Hz
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

wav=oljud_stereo.wav
sockfile=verify_oljud_stereo.sock
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
word("start test/et19.elf"); typ(["ret"])
time.sleep(6.0)
sock.close()
PY

cleanup
trap - EXIT

ok=1
code=$(grep -o '\[syscall\] exit code=-\?[0-9]*' serial.log | tail -1 | sed 's/.*=//')
if [ "$code" = "7" ]; then
  echo "PASS: 19_stereo.c0 exit code 7 (all checks)"
else
  echo "FAIL: 19_stereo.c0 exit code ${code:-<none>}, expected 7"
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
loud = [i for i in range(len(left)) if abs(left[i]) > 4000 or abs(right[i]) > 4000]
if not loud:
    print("FAIL: the recording is silent")
    sys.exit(1)
segs = [[loud[0], loud[0]]]
for i in loud[1:]:
    if i - segs[-1][1] > rate // 10:
        segs.append([i, i])
    else:
        segs[-1][1] = i
print("tones: %s" % ", ".join("%.2f s" % ((b - a + 1) / rate) for a, b in segs))
if len(segs) != 3:
    print("FAIL: expected three tones, found %d" % len(segs))
    sys.exit(1)

def freq(side, a, b):
    xs = [i for i in range(a + 1, b + 1) if (side[i - 1] >= 0) != (side[i] >= 0)]
    if len(xs) < 3:
        return 0
    return (len(xs) - 1) / 2 / ((xs[-1] - xs[0]) / rate)

def peak(side, a, b):
    return max(abs(v) for v in side[a:b + 1])

ok = True
(a1, b1), (a2, b2), (a3, b3) = segs
f1, f2, f3 = freq(left, a1, b1), freq(right, a2, b2), freq(left, a3, b3)
print("left tone %.1f Hz (right peak %d), right tone %.1f Hz (left peak %d), both %.1f Hz"
      % (f1, peak(right, a1, b1), f2, peak(left, a2, b2), f3))
if not (432 <= f1 <= 450 and peak(right, a1, b1) < 500):
    print("FAIL: the first tone is not 441 Hz on the left alone"); ok = False
if not (864 <= f2 <= 900 and peak(left, a2, b2) < 500):
    print("FAIL: the second tone is not 882 Hz on the right alone"); ok = False
differ = sum(1 for i in range(a3, b3 + 1) if abs(left[i] - right[i]) > 200)
if not (432 <= f3 <= 450 and peak(right, a3, b3) > 4000 and differ < (b3 - a3) // 50):
    print("FAIL: the 16-bit mono tone is not the same 441 Hz on both sides"); ok = False
for (a, b) in segs:
    if not 0.45 <= (b - a + 1) / rate <= 0.56:
        print("FAIL: a tone lasted %.3f s, expected 0.5" % ((b - a + 1) / rate)); ok = False
if ok:
    print("PASS: left, right and 16-bit mono each where they belong")
sys.exit(0 if ok else 1)
PY

if grep -q 'PANIC' serial.log; then echo "FAIL: kernel panic"; ok=0; fi
if [ "$ok" -eq 1 ]; then
  echo "PASS: oljud plays 16-bit stereo and mono"
  exit 0
fi
exit 1
