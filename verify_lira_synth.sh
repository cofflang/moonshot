#!/usr/bin/env bash
#
# verify_lira_synth.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Checks lira's synth by listening to it, the way verify_oljud.sh checks
# oljud. elf_tests/15_synth.c0 builds a noter song of two notes at once, A4
# and E5, one second long, and plays it with synth_play. QEMU records the
# Sound Blaster 16 to a wav file, and this measures it.
#
#   - the sound lasts one second (0.95 to 1.10 s);
#   - there is strong energy at 440 Hz and at 659.26 Hz, both of them, so
#     two voices really were mixed and neither was lost;
#   - there is little at frequencies where neither note nor any of their
#     odd harmonics (a square wave has only odd ones) should be, so the
#     notes came out at the right pitch and not merely near it.
#
# The energies come from a Goertzel filter, one frequency at a time, which
# needs nothing beyond python's standard library.
#
# The program's own exit code (11) checks the arithmetic behind this.

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

wav=lira_synth.wav
sockfile=verify_lira_synth.sock
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
word("spawn3 test/et15.elf"); typ(["ret"])
# One second of sound plus up to two halves of latency, then the exit.
time.sleep(4.0)
sock.close()
EOF

cleanup
trap - EXIT

ok=1

if grep -q '^\[oljud\] Sound Blaster 16, DSP 4\.' serial.log; then
  echo "PASS: card found ($(grep -m1 '^\[oljud\] Sound Blaster' serial.log))"
else
  echo "FAIL: oljud did not find the SB16"
  grep '^\[oljud\]' serial.log
  ok=0
fi

code=$(grep -o '\[syscall\] exit code=-\?[0-9]*' serial.log | tail -1 | sed 's/.*=//')
if [ "$code" = "11" ]; then
  echo "PASS: 15_synth.c0 exit code 11 (all checks)"
else
  echo "FAIL: 15_synth.c0 exit code ${code:-<none>}, expected 11"
  ok=0
fi

if [ ! -s "$wav" ]; then
  echo "FAIL: QEMU wrote no $wav"
  exit 1
fi

python3 - "$wav" <<'EOF' || ok=0
import sys, struct

# Read by hand rather than with the wave module, since QEMU writes the sizes into
# the header only when it shuts down cleanly, and a run that ends any other
# way leaves them 0, which the wave module rejects. The layout is QEMU's
# fixed 44-byte one, "fmt " at 12, "data" at 36.
data = open(sys.argv[1], "rb").read()
if data[0:4] != b"RIFF" or data[12:16] != b"fmt " or data[36:40] != b"data":
    print("FAIL: not the 44-byte wav header QEMU writes")
    sys.exit(1)
ch, rate = struct.unpack("<HI", data[22:28])
width = struct.unpack("<H", data[34:36])[0] // 8
raw = data[44:]
raw = raw[:len(raw) - len(raw) % (2 * ch)]
if width != 2:
    print("FAIL: expected 16-bit wav from QEMU, got %d bytes per sample" % width)
    sys.exit(1)
vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
mono = vals[::ch]
print("recording: %d Hz, %d channel(s), %.2f s" % (rate, ch, len(mono) / rate))

import math

# Two voices of +-16 around 128 in 8 bits, about +-8000 here when they agree,
# 0 when they cancel. Silence is 0.
loud = [i for i, v in enumerate(mono) if abs(v) > 2000]
if not loud:
    print("FAIL: the recording is silent")
    sys.exit(1)
start, end = loud[0], loud[-1]
dur = (end - start + 1) / rate
print("sound: %.3f s" % dur)

seg = mono[start:end + 1]
def power(f):
    # Goertzel, the strength of one frequency in seg, normalised by length.
    w = 2 * math.cos(2 * math.pi * f / rate)
    s1 = s2 = 0.0
    for x in seg:
        s1, s2 = x + w * s1 - s2, s1
    return (s1 * s1 + s2 * s2 - w * s1 * s2) / len(seg) ** 2

notes = {440.0: power(440.0), 659.26: power(659.26)}
others = {f: power(f) for f in (300.0, 500.0, 550.0, 600.0, 750.0, 900.0)}
loudest_other = max(others.values())
for f, p in notes.items():
    print("%7.2f Hz: %10.0f" % (f, p))
print("loudest elsewhere: %.0f (at %.0f Hz)" % (loudest_other, max(others, key=others.get)))

ok = True
if not 0.95 <= dur <= 1.10:
    print("FAIL: sound lasts %.3f s, expected 1 s" % dur); ok = False
for f, p in notes.items():
    if p < 50 * loudest_other:
        print("FAIL: %.2f Hz is not clearly there (%.0f vs %.0f elsewhere)" % (f, p, loudest_other)); ok = False
if ok:
    print("PASS: one second of A4 and E5 together, both at the right pitch")
sys.exit(0 if ok else 1)
EOF

panics=$(grep -c 'PANIC' serial.log || true)
if [ "$panics" -ne 0 ]; then
  echo "FAIL: kernel panic during the run"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: lira's synth plays two notes at once, at the right pitches"
  exit 0
fi
echo "FAIL: lira synth"
exit 1
