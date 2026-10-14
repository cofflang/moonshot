#!/usr/bin/env bash
#
# verify_oljud_mix.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Two programs sounding at once are heard together. oljud keeps a queue per
# task and adds them up as 16-bit samples, so a second program's sound is
# mixed in rather than waiting for the first to finish.
#
#   1. Two copies of test/tone.elf are started one after the other, a 330 Hz
#      and a 550 Hz square wave, six seconds each. Typing the second command
#      takes a few seconds, so they overlap by about three.
#   2. The recording is cut into half-second windows, and in at least four
#      windows in a row both pitches are strong at once. With one shared
#      queue the second tone only starts when the first has finished, so
#      no window holds both.
#   3. Both programs exit 0 and the kernel did not panic.
#
# The energies come from a Goertzel filter, as in verify_lira_synth.sh.

set -u
cd "$(dirname "$0")"

./gen_elf_tests.sh >/dev/null || exit 1
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

rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

wav=oljud_mix.wav
sockfile=verify_oljud_mix.sock
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

python3 - "$sockfile" <<'EOF'
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
word("start test/tone.elf 330"); typ(["ret"])
word("start test/tone.elf 550"); typ(["ret"])
# Six seconds of each, overlapping, then the drain and the exits.
time.sleep(10.0)
sock.close()
EOF

cleanup
trap - EXIT

ok=1
exits=$(grep -c '\[syscall\] exit code=0$' serial.log || true)
if [ "$exits" -ge 2 ]; then
  echo "PASS: both tone programs exited 0"
else
  echo "FAIL: expected two tone programs to exit 0, saw $exits"
  ok=0
fi

if [ ! -s "$wav" ]; then
  echo "FAIL: QEMU wrote no $wav"
  exit 1
fi

python3 - "$wav" <<'EOF' || ok=0
import sys, struct, math
data = open(sys.argv[1], "rb").read()
if data[0:4] != b"RIFF" or data[12:16] != b"fmt " or data[36:40] != b"data":
    print("FAIL: not the 44-byte wav header QEMU writes")
    sys.exit(1)
ch, rate = struct.unpack("<HI", data[22:28])
raw = data[44:]
raw = raw[:len(raw) - len(raw) % (2 * ch)]
vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
mono = vals[::ch]
print("recording: %d Hz, %.2f s" % (rate, len(mono) / rate))

def goertzel(xs, f):
    w = 2 * math.pi * f / rate
    c = 2 * math.cos(w)
    s1 = s2 = 0.0
    for x in xs:
        s0 = x + c * s1 - s2
        s2, s1 = s1, s0
    return math.sqrt(max(s1 * s1 + s2 * s2 - c * s1 * s2, 0.0)) / len(xs)

win = rate // 2
both = []
for start in range(0, len(mono) - win, win):
    xs = mono[start:start + win]
    a, b = goertzel(xs, 330), goertzel(xs, 550)
    both.append(a > 1500 and b > 1500)
run = best = 0
for x in both:
    run = run + 1 if x else 0
    best = max(best, run)
print("half-second windows with both pitches: %d, longest run %d" % (sum(both), best))
if best < 4:
    print("FAIL: the two tones were never heard together for two seconds")
    sys.exit(1)
print("PASS: both tones sound together")
EOF

panics=$(grep -c 'PANIC' serial.log || true)
if [ "$panics" -gt 0 ]; then
  echo "FAIL: kernel panic during the run"
  ok=0
fi

echo
if [ "$ok" -eq 1 ]; then
  echo "PASS: oljud mixes two programs"
  exit 0
fi
echo "FAIL: oljud_mix"
exit 1
