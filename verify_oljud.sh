#!/usr/bin/env bash
#
# verify_oljud.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Checks oljud, the Sound Blaster 16 driver, by listening to it.
#
# QEMU's `-audiodev wav` writes whatever the emulated card plays to a file,
# so this does not stop at "it did not crash". It boots with an SB16, spawns
# elf_tests/13_oljud.c0, which plays one second of a 441 Hz square wave
# through sound(), and then measures the recording.
#
#   - the tone is there, and lasts one second (0.95 to 1.10 s), which only
#     comes out right if the card runs at the rate oljud asked for and every
#     queued byte was played once;
#   - its frequency is 441 Hz (within 2%), from the zero crossings;
#   - every half-period inside it is the same length (25 card samples), so
#     no half of the DMA page was skipped, played twice or refilled while
#     the card was reading it. Any of those breaks the square wave's rhythm
#     at a 2048-byte boundary, which the frequency alone would average away.
#
#   - a second tone, stopped with sound(0, -1) about 0.3 s in, really stops
#     there rather than playing out its second.
#
# The program's own exit code (10) checks the syscall's answers and the
# queue's pace; verify_elf_backend.sh runs the same program.

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

wav=oljud.wav
sockfile=verify_oljud.sock
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
word("spawn3 test/et13.elf"); typ(["ret"])
# One second of tone, up to two halves of latency, then the 64KB of
# silence the last check queues, so wait for the exit, then a little more.
time.sleep(6.0)
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
if [ "$code" = "10" ]; then
  echo "PASS: 13_oljud.c0 exit code 10 (all checks)"
else
  echo "FAIL: 13_oljud.c0 exit code ${code:-<none>}, expected 10"
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

# The tone is +-64 around 128 in 8 bits, about +-16000 here. Silence is 0.
loud = [i for i, v in enumerate(mono) if abs(v) > 4000]
if not loud:
    print("FAIL: the recording is silent")
    sys.exit(1)
# Two tones. The second second-long one is stopped with sound(0, -1) about
# 0.3 s in. Split the recording where it is quiet for more than 0.2 s.
segs = [[loud[0], loud[0]]]
for i in loud[1:]:
    if i - segs[-1][1] > rate // 5:
        segs.append([i, i])
    else:
        segs[-1][1] = i
if len(segs) != 2:
    print("FAIL: expected two tones in the recording, found %d" % len(segs))
    sys.exit(1)
start, end = segs[0]
dur = (end - start + 1) / rate
cut = (segs[1][1] - segs[1][0] + 1) / rate
print("tone: %.3f s; the stopped tone: %.3f s" % (dur, cut))

crossings = [i for i in range(start + 1, end + 1)
             if (mono[i - 1] >= 0) != (mono[i] >= 0)]
freq = (len(crossings) - 1) / 2 / ((crossings[-1] - crossings[0]) / rate)
print("frequency: %.1f Hz" % freq)

# A half-period is 25 card samples; at the recording's rate that is
# 25 * rate / 22050 frames, give or take one for resampling.
want = 25 * rate / 22050
gaps = [b - a for a, b in zip(crossings, crossings[1:])]
bad = [(crossings[i], g) for i, g in enumerate(gaps) if abs(g - want) > 2]
print("half-periods: %d, %d off the %.1f-frame rhythm" % (len(gaps), len(bad), want))

ok = True
if not 0.95 <= dur <= 1.10:
    print("FAIL: tone lasts %.3f s, expected 1 s" % dur); ok = False
if not 432 <= freq <= 450:
    print("FAIL: frequency %.1f Hz, expected 441" % freq); ok = False
if bad:
    print("FAIL: broken rhythm at frame(s) %s" % bad[:5]); ok = False
# Stopped after 30 ticks, 0.3 s after it was queued. Less than that is heard,
# because the tone waited up to two DMA halves (0.19 s) before the card got
# to it. A flush that did nothing would let the whole second play.
if not 0.05 <= cut <= 0.45:
    print("FAIL: the stopped tone lasted %.3f s, expected about 0.3" % cut); ok = False
if ok:
    print("PASS: one second of 441 Hz, every half-period intact")
sys.exit(0 if ok else 1)
EOF

panics=$(grep -c 'PANIC' serial.log || true)
if [ "$panics" -ne 0 ]; then
  echo "FAIL: kernel panic during the run"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: oljud plays what ring 3 hands it, at the right pace"
  exit 0
fi
echo "FAIL: oljud"
exit 1
