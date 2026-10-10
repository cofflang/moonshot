#!/usr/bin/env bash
#
# verify_lira.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Uses lira, the piano roll, the way a person would, and checks each step
# from the screen and from what the sound card played.
#
#   1. lira opens demo.not ("Gubben Noak", seeded by the kernel) and draws
#      it, notes where the song says they are, and none where it says none.
#   2. A click on an empty cell (A3, step 8) puts a note there. Two presses
#      of "," take the velocity from 100 to 68, and a G3 placed then shows
#      a velocity bar of exactly 68/127 of the note, against A3's 100/127.
#   3. Space plays the song. QEMU records the card, and the song lasts 7 s (56
#      steps at 120 beats a minute), so the streaming kept up, and 220 Hz,
#      A3, is heard exactly where the new note is and not before it.
#   3b. l and space play it on a loop, and space stops it 9.5 s later. The
#      recording runs past the song's 7 s, the song starts over at 7.0 s,
#      and it stops at about 9.5 s.
#   4. s saves song.not, Esc quits, and a second lira opens song.not with
#      the new note in it, so the save went through writefile() and came
#      back through readfile() rather than living on in memory.
#   5. A click on the note removes it.
#
# Where things are on screen is found from the screen, not assumed. The
# leftmost note of the demo is C4 at step 0, so its top-left pixel gives the
# grid's origin, and every cell is 12 pixels wide and 12 high from there
# (lira's COL_W, and ROW_H for the kernel's 8x8 font).

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

wav=lira.wav
sockfile=verify_lira.sock
rm -f serial.log "$sockfile" "$wav" lira_*.ppm
qemu-system-x86_64 -cdrom moonshot.iso \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -audiodev wav,id=snd0,path="$wav" -device sb16,audiodev=snd0 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

sleep 3

python3 - "$sockfile" "$wav" <<'EOF'
import socket, sys, time, struct, math

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
sock.setblocking(False)
time.sleep(0.2)

def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    try:
        sock.recv(65536)
    except BlockingIOError:
        pass

def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])

def shot(name):
    send("screendump %s" % name, settle=1.0)
    with open(name, "rb") as f:
        data = f.read()
    head = data.split(b"\n", 3)
    w, h = map(int, head[1].split())
    return w, h, head[3]

def px(img, x, y):
    w, h, d = img
    i = (y * w + x) * 3
    return d[i], d[i + 1], d[i + 2]

pos = [512, 384]
def park():
    for _ in range(9):
        send("mouse_move -100 -100", settle=0.04)
    pos[0] = pos[1] = 0

def move_to(x, y):
    while pos[0] != x or pos[1] != y:
        dx = max(-100, min(100, x - pos[0]))
        dy = max(-100, min(100, y - pos[1]))
        send("mouse_move %d %d" % (dx, dy), settle=0.04)
        pos[0] += dx
        pos[1] += dy

def click(x, y):
    move_to(x, y)
    send("mouse_button 1", settle=0.3)
    send("mouse_button 0", settle=0.3)

NOTE = (232, 162, 60)   # lira's COL_NOTE
VEL = (255, 226, 176)   # lira's COL_VEL, the velocity bar
fails = []
def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)

def origin(img):
    # The leftmost note pixels belong to C4 and C3 at step 0; the topmost of
    # them is C4's. A note's fill starts 2 pixels into its cell.
    w, h, d = img
    best = None
    for y in range(h):
        for x in range(w):
            if px(img, x, y) == NOTE:
                if best is None or x < best[0] or (x == best[0] and y < best[1]):
                    best = (x, y)
                break
    if best is None:
        return None
    return best[0] - 2, best[1] - 2

def cell(org, pitch, step):
    # The centre of a cell, relative to C4 at step 0.
    return org[0] + step * 12 + 6, org[1] + (60 - pitch) * 12 + 6

def vel_bar(img, org, pitch, step, steps):
    # The velocity bar's length in pixels, the run of VEL along the note's
    # bar row, two rows above the bottom of its fill (ROW_H - 5 from the
    # top of the row).
    x0 = org[0] + step * 12
    y = org[1] + (60 - pitch) * 12 + 7
    return sum(1 for x in range(x0, x0 + steps * 12) if px(img, x, y) == VEL)

def is_note(img, org, pitch, step):
    x, y = cell(org, pitch, step)
    return px(img, x, y) == NOTE

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("spawn3 lira.elf"); typ(["ret"]); time.sleep(2.0)
park()

print("1. the demo song")
a = shot("lira_a.ppm")
org = origin(a)
check(org is not None, "notes on screen")
if org is None:
    sys.exit(1)
print("     grid origin (C4, step 0) at %d,%d" % org)
for p, k in ((60, 0), (60, 4), (64, 12), (62, 16), (65, 28), (55, 20), (48, 2)):
    check(is_note(a, org, p, k), "demo note at pitch %d step %d" % (p, k))
for p, k in ((57, 8), (60, 3), (62, 0), (64, 16)):
    check(not is_note(a, org, p, k), "no note at pitch %d step %d" % (p, k))

print("2. a click adds a note")
# The first click on a window only focuses it, so give it one on the
# pitch names left of the grid, where a click does nothing else either way.
click(org[0] - 20, org[1] + 6)
x, y = cell(org, 57, 8)
click(x, y)
park()
b = shot("lira_b.ppm")
check(is_note(b, org, 57, 8) and is_note(b, org, 57, 11), "A3 at steps 8-11")
check(not is_note(b, org, 57, 12), "and not at step 12 (length 4)")
typ(["comma", "comma"])
x, y = cell(org, 55, 8)
click(x, y)
park()
b2 = shot("lira_b2.ppm")
a3, g3 = vel_bar(b2, org, 57, 8, 4), vel_bar(b2, org, 55, 8, 4)
print("     velocity bars: A3 %d px, G3 %d px" % (a3, g3))
# A 4-step note's bar spans 4 * 12 - 3 = 45 pixels at velocity 127.
check(a3 == 45 * 100 // 127 and g3 == 45 * 68 // 127, "velocity 100 and 68 drawn to scale")

print("3. it plays")
typ(["spc"])
time.sleep(8.5)
print("3b. on a loop, stopped at 9.5 s")
typ(["l"]); time.sleep(0.3)
typ(["spc"])
time.sleep(9.5)
typ(["spc"])
time.sleep(1.5)

print("4. saved, and read back by a second lira")
typ(["s"]); time.sleep(0.5)
typ(["esc"]); time.sleep(1.0)
# An exited program's window stays up, showing its last frame, and keeps the
# focus. Alt+W closes it and hands the focus back to the shell. Without that
# the next command is typed into nothing and the previous frame is what gets
# checked. The second lira's tile is found from the screen like the first.
send("sendkey alt-w", settle=0.8)
word("spawn3 lira.elf"); typ(["ret"]); time.sleep(2.0)
park()
c = shot("lira_c.ppm")
org2 = origin(c)
check(org2 is not None and is_note(c, org2, 57, 8), "the new note is in song.not")

print("5. a click removes it")
click(org2[0] - 20, org2[1] + 6)
x, y = cell(org2, 57, 9)
click(x, y)
park()
e = shot("lira_e.ppm")
check(not is_note(e, org2, 57, 8), "A3 gone")
check(is_note(e, org2, 60, 0), "the rest of the song still there")

sock.close()
open("lira_steps.result", "w").write("FAIL\n" if fails else "PASS\n")
EOF

cleanup
trap - EXIT

ok=1
if [ "$(cat lira_steps.result 2>/dev/null)" != "PASS" ]; then ok=0; fi
rm -f lira_steps.result

python3 - "$wav" <<'EOF' || ok=0
import sys, struct, math

data = open(sys.argv[1], "rb").read()
if data[0:4] != b"RIFF" or data[36:40] != b"data":
    print("FAIL: not the 44-byte wav header QEMU writes")
    sys.exit(1)
ch, rate = struct.unpack("<HI", data[22:28])
raw = data[44:]
raw = raw[:len(raw) - len(raw) % (2 * ch)]
mono = struct.unpack("<%dh" % (len(raw) // 2), raw)[::ch]

loud = [i for i, v in enumerate(mono) if abs(v) > 1500]
if not loud:
    print("FAIL: nothing was played")
    sys.exit(1)
# Two playbacks, once through, then the loop that is stopped at 9.5 s. Split
# where it is quiet for more than 0.3 s (the song's own rests are 0.125 s).
segs = [[loud[0], loud[0]]]
for i in loud[1:]:
    if i - segs[-1][1] > rate * 3 // 10:
        segs.append([i, i])
    else:
        segs[-1][1] = i
if len(segs) != 2:
    print("FAIL: expected two playbacks in the recording, found %d" % len(segs))
    sys.exit(1)
start, end = segs[0]
dur = (end - start + 1) / rate
looped = (segs[1][1] - segs[1][0] + 1) / rate
print("3. playback: %.3f s; looped and stopped: %.3f s" % (dur, looped))

def power(f, t0, t1, base=None):
    if base is None:
        base = start
    seg = mono[base + int(t0 * rate):base + int(t1 * rate)]
    w = 2 * math.cos(2 * math.pi * f / rate)
    s1 = s2 = 0.0
    for x in seg:
        s1, s2 = x + w * s1 - s2, s1
    return (s1 * s1 + s2 * s2 - w * s1 * s2) / len(seg) ** 2

# Steps are 0.125 s. The new A3 sounds from step 8 to 12, 1.0 to 1.5 s.
# Before it, steps 0-3 are C4 over C3, and nothing there is near 220 Hz.
with_a3 = power(220.0, 1.05, 1.45)
before = power(220.0, 0.05, 0.35)
c4 = power(261.63, 0.05, 0.35)
print("   220 Hz while A3 plays: %.0f, before it: %.0f; C4 at the start: %.0f"
      % (with_a3, before, c4))

ok = True
if not 6.9 <= dur <= 7.1:
    print("FAIL: the song should last 7.0 s"); ok = False
if with_a3 < 20 * max(before, 1):
    print("FAIL: A3 is not where the new note is"); ok = False
if c4 < 20 * max(before, 1):
    print("FAIL: the demo's first C4 is missing"); ok = False
# The loop. Past 7 s the song starts over, so C4 is heard at 7.05-7.35 s just
# as at 0.05-0.35 s. At 6.6-6.9 s, the song's last half note, it is C4 too,
# so compare against 220 Hz there instead, which is not playing.
again = power(261.63, 7.05, 7.35, segs[1][0])
print("   C4 after the loop point: %.0f" % again)
if again < 20 * max(before, 1):
    print("FAIL: the song did not start over at 7 s"); ok = False
# Stopped 9.5 s after space, give or take the keys' timing; without the loop
# the sound would end at 7 s. This window is too coarse to tell an emptied
# queue from a full one (about 0.4 s apart); verify_oljud.sh checks that.
if not 9.0 <= looped <= 10.0:
    print("FAIL: the looped playback lasted %.3f s, expected about 9.5" % looped); ok = False
if ok:
    print("PASS: the song plays for 7 s with the new note where it was placed, loops, and stops")
sys.exit(0 if ok else 1)
EOF

panics=$(grep -c 'PANIC' serial.log || true)
if [ "$panics" -ne 0 ]; then
  echo "FAIL: kernel panic during the run"
  ok=0
fi
if grep -q 'lager\] dealloc: not a live block' serial.log; then
  echo "FAIL: lira freed something it did not own"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: lira edits, plays, saves and reloads a song"
  exit 0
fi
echo "FAIL: lira"
exit 1
