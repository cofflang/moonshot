#!/usr/bin/env bash
#
# verify_infecteria_sound.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Infecteria's music and sound effects, heard through QEMU's recording of
# the Sound Blaster 16, in a world with one cell and no antibacteria
# (infecteria.seed "1 0 1").
#
#   1. Music plays while the game runs. Nearly every tenth of a second of
#      the first stretch of the recording is loud.
#   2. Standing in the cell until it is fully infected plays the ready blip,
#      whose second tone is 1500 Hz. Some 50ms window holds far more 1500 Hz
#      than the music ever does.
#   3. Eating the cell wins, and the win jingle ends on E6, 1319 Hz, which is
#      heard after the blip.
#   4. The music stops at the win. The last second of the recording, on the
#      end screen, is quiet.
#
# The energies come from a Goertzel filter, as in verify_lira_synth.sh.

set -u
cd "$(dirname "$0")"

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

wav=infecteria_sound.wav
sockfile=verify_infecteria_sound.sock
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
word("make infecteria.seed"); typ(["ret"]); time.sleep(0.6)
word("write infecteria.seed 1 0 1"); typ(["ret"]); time.sleep(0.6)
word("start infecteria.elf"); typ(["ret"]); time.sleep(4.0)
typ(["alt-tab"]); time.sleep(1.5)
typ(["spc"]); time.sleep(2.0)
# Into the cell, and stay until it is fully infected (one second inside).
send("sendkey down 550", settle=1.2)
time.sleep(2.0)
typ(["e"]); time.sleep(3.0)
sock.close()
EOF

cleanup
trap - EXIT

ok=1
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
secs = len(mono) / rate
print("recording: %d Hz, %.2f s" % (rate, secs))

def goertzel(xs, f):
    w = 2 * math.pi * f / rate
    c = 2 * math.cos(w)
    s1 = s2 = 0.0
    for x in xs:
        s0 = x + c * s1 - s2
        s2, s1 = s1, s0
    return math.sqrt(max(s1 * s1 + s2 * s2 - c * s1 * s2, 0.0)) / len(xs)

def rms(xs):
    return math.sqrt(sum(x * x for x in xs) / max(len(xs), 1))

ok = True
# Where the sound starts. The program starts its music at launch.
first = next((i for i, v in enumerate(mono) if abs(v) > 500), None)
if first is None:
    print("FAIL: the recording is silent")
    sys.exit(1)

# 1. Music, three seconds of it from the first sound.
tenth = rate // 10
loud = [rms(mono[first + k * tenth:first + (k + 1) * tenth]) > 300 for k in range(30)]
print("music: %d of 30 tenths loud" % sum(loud))
if sum(loud) < 27:
    print("FAIL: no steady music while the game runs")
    ok = False

# 2 and 3. 50ms windows, energy at 1500 Hz (the blip) and 1319 Hz (the end
# of the win jingle).
win = rate // 20
e1500, e1319 = [], []
for start in range(first, len(mono) - win, win):
    xs = mono[start:start + win]
    e1500.append(goertzel(xs, 1500))
    e1319.append(goertzel(xs, 1319))
med = sorted(e1500)[len(e1500) // 2]
blip = max(range(len(e1500)), key=lambda i: e1500[i])
print("1500 Hz: loudest %.0f at %.2f s, median %.0f" % (e1500[blip], blip / 20, med))
if e1500[blip] < 6 * med or e1500[blip] < 800:
    print("FAIL: no ready blip when the cell was fully infected")
    ok = False
after = e1319[blip + 1:]
jingle = max(after) if after else 0
print("1319 Hz after the blip: %.0f" % jingle)
if jingle < 800:
    print("FAIL: no win jingle after eating the last cell")
    ok = False

# 4. The end screen is quiet.
tail = rms(mono[-rate:])
print("last second: rms %.0f" % tail)
if tail > 150:
    print("FAIL: the music went on after the win")
    ok = False
sys.exit(0 if ok else 1)
EOF

panics=$(grep -c 'PANIC' serial.log || true)
if [ "$panics" -gt 0 ]; then
  echo "FAIL: kernel panic during the run"
  ok=0
fi

echo
if [ "$ok" -eq 1 ]; then
  echo "PASS: Infecteria plays music and its sound effects"
  exit 0
fi
echo "FAIL: infecteria sound"
exit 1
