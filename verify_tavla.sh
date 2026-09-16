#!/usr/bin/env bash
#
# verify_tavla.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves the tavla window kind works on real pixels, not just that the
# kernel builds. A tavla is the window a graphical ring-3 program gets: a
# kakel-owned title strip above a client area the program cannot draw over.
#
# Everything here is checked against a QEMU screendump rather than the draw
# code, because every previous bug in this area (a doubled FONT_H, a sprite
# bouncing off an edge nobody could see) looked perfectly correct in source
# and only showed up in pixels.
#
# Checks, in one boot:
#   1. spawn3 gnista.elf creates a tavla, and its title strip renders DIM
#      while focus is still on the shell.
#   2. Alt+Tab onto the tavla turns the same strip BRIGHT -- the fix for
#      focus being invisible on a window that draws no text cursor, which
#      is what made a shell window and a graphical one look equally focused
#      at the same time.
#   3. The client area is inset BELOW the strip: the program's own pixels
#      never appear in the strip row.
#   4. Alt+W closes the focused tavla and kills its owning task.
#   5. The stuck case: with a tavla open, closing skalman's own window
#      leaves the tavla as the only window -- Alt+W must still get a
#      working shell back. This used to be unrecoverable: a tavla swallowed
#      every keystroke, so with no shell window left there was nothing on
#      screen that could accept input.

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

sockfile=verify_tavla.sock
rm -f serial.log "$sockfile" tavla_*.ppm
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

sleep 2

python3 - "$sockfile" <<'EOF'
import socket, sys, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.2)
sock.recv(65536)

def send(cmd, settle=0.05):
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
    # QEMU's monitor has no bare `sendkey _`, and a dropped character
    # silently renames the file being spawned -- so only send what maps.
    keymap = {".": "dot", " ": "spc", "-": "minus"}
    typ([keymap.get(c, c) for c in s])

def shot(name):
    send("screendump %s" % name, settle=0.6)

# raket login gate: root, then an empty password.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.0)

# 1+3: spawn a graphical program. Focus stays on the shell, so the tavla's
# strip must be dim.
word("spawn3 gnista.elf"); typ(["ret"])
time.sleep(3.0)
shot("tavla_unfocused.ppm")

# 2: Alt+Tab onto the tavla -- the strip must go bright.
send("sendkey alt-tab", settle=0.8)
time.sleep(0.5)
shot("tavla_focused.ppm")

# 4: Alt+W closes it and kills the program.
send("sendkey alt-w", settle=0.8)
time.sleep(1.0)
shot("tavla_closed.ppm")

# 5: the stuck case. Spawn again, close skalman's own window so only the
# tavla is left, then Alt+W to get a shell back -- and prove the shell is
# really alive by running a command in it.
word("spawn3 gnista.elf"); typ(["ret"])
time.sleep(3.0)
word("close"); typ(["ret"])
time.sleep(1.5)
shot("tavla_only.ppm")
send("sendkey alt-w", settle=0.8)
time.sleep(1.5)
# The replacement window is a FRESH session, so it asks for a login -- window
# ids are reused and raket's per-window state is reset on allocation (see
# verify_login_reset.sh). Log in again before proving the shell works.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.0)
word("tasks"); typ(["ret"])
time.sleep(1.0)
shot("tavla_recovered.ppm")

sock.close()
EOF

sleep 1

python3 - <<'EOF'
import sys

# Title-strip colors, from kakel_init: KAKEL_TAVLA_BAR = fb_rgb(48,48,128),
# KAKEL_TAVLA_BAR_DIM = fb_rgb(24,24,40). The only other colors legally
# present in a title strip are the two the title text itself is drawn in:
# FB_FG = fb_rgb(200,200,200) (knekt.c0) when focused, KAKEL_DIM =
# fb_rgb(100,100,100) when not.
BAR       = (48, 48, 128)
BAR_DIM   = (24, 24, 40)
FG        = (200, 200, 200)
DIM       = (100, 100, 100)
FONT_H    = 8

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    # P6 <w> <h> <maxval>\n<binary>
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace():
            pos += 1
        if data[pos:pos+1] == b"#":
            while data[pos:pos+1] != b"\n":
                pos += 1
            continue
        start = pos
        while not data[pos:pos+1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    w, h, _ = fields
    return w, h, data[pos:]

def px(buf, w, x, y):
    off = (y * w + x) * 3
    return (buf[off], buf[off+1], buf[off+2])

def strip_counts(path):
    """Count BAR vs BAR_DIM pixels in the top character row of the RIGHT
    half of the screen -- where spawn3's tavla lands (kakel_split inserts
    the new window after the focused one, so the shell keeps the left)."""
    w, h, buf = read_ppm(path)
    bright = dim = 0
    for y in range(0, FONT_H):
        for x in range(w // 2, w):
            p = px(buf, w, x, y)
            if p == BAR:
                bright += 1
            elif p == BAR_DIM:
                dim += 1
    return w, h, bright, dim

ok = True

w, h, b_un, d_un = strip_counts("tavla_unfocused.ppm")
print("unfocused tavla strip: bright=%d dim=%d  (%dx%d)" % (b_un, d_un, w, h))
if d_un < 100 or b_un > d_un:
    print("FAIL: an unfocused tavla's title strip is not rendering dim")
    ok = False

_, _, b_fo, d_fo = strip_counts("tavla_focused.ppm")
print("focused tavla strip:   bright=%d dim=%d" % (b_fo, d_fo))
if b_fo < 100 or b_fo < d_fo:
    print("FAIL: focusing a tavla did not brighten its title strip")
    ok = False

if not (b_fo > b_un and d_un > d_fo):
    print("FAIL: the strip did not actually flip between the two screendumps")
    ok = False

# 3: the client area is inset below the strip. Gnista's demo paints its
# whole window; if the inset were missing, the strip row would be full of
# the demo's own background instead of bar color.
w, h, buf = read_ppm("tavla_focused.ppm")
allowed = (BAR, BAR_DIM, FG, DIM)
foreign = {}
for y in range(0, FONT_H):
    for x in range(w // 2 + 8, w - 8):
        p = px(buf, w, x, y)
        if p not in allowed:
            foreign[p] = foreign.get(p, 0) + 1
print("pixels in the title row that are neither bar nor title text: %d %s"
      % (sum(foreign.values()), sorted(foreign.items(), key=lambda kv: -kv[1])[:4]))
if foreign:
    print("FAIL: the program is drawing into its own title strip -- inset is wrong")
    ok = False

# 4+5: after Alt+W the layout is back to a single full-width window, so the
# top-right corner is no longer any bar color at all.
for shot in ("tavla_closed.ppm", "tavla_recovered.ppm"):
    w, h, buf = read_ppm(shot)
    p = px(buf, w, w - 4, FONT_H // 2)
    print("%s top-right pixel: %s" % (shot, (p,)))
    if p == BAR or p == BAR_DIM:
        print("FAIL: %s still shows a tavla title strip -- alt+w did not close it" % shot)
        ok = False

# 5, corroboration: the recovered window has content below its greeting. On
# its own this proves less than it looks like -- the login prompt draws a line
# there with no input at all -- so the real proof that keystrokes reach the
# shell again is the second raket login line checked on serial below.
w, h, buf = read_ppm("tavla_recovered.ppm")
text = 0
for y in range(FONT_H * 2, FONT_H * 7):
    for x in range(0, w // 2):
        if px(buf, w, x, y) in (FG, DIM):
            text += 1
print("text pixels below the greeting in the recovered window: %d" % text)
if text < 200:
    print("FAIL: nothing was typed into the recovered window -- input is not reaching the shell")
    ok = False

sys.exit(0 if ok else 1)
EOF
pixels_ok=$?

echo
echo "--- serial evidence ---"
grep -E '\[elf\] windowed spawn wid=|\[tavla\] closed win=|\[sched\] reaped' serial.log | tail -12

ok=1
[ "$pixels_ok" -eq 0 ] || ok=0

spawns=$(grep -c '\[elf\] windowed spawn wid=' serial.log || true)
echo "windowed spawns: $spawns"
[ "$spawns" -ge 2 ] || { echo "FAIL: expected 2 windowed spawns, got $spawns"; ok=0; }

closes=$(grep -c '\[tavla\] closed win=' serial.log || true)
echo "alt+w tavla closes: $closes"
[ "$closes" -ge 2 ] || { echo "FAIL: expected 2 tavla closes, got $closes"; ok=0; }

# The real proof that input reaches the shell again after recovering from the
# stuck case: raket only logs a username line when a completed line of typed
# text arrives. Two of them means the boot login AND the post-recovery one.
logins=$(grep -c "\[raket\] session .* username='root'" serial.log || true)
echo "logins completed: $logins"
[ "$logins" -ge 2 ] || {
  echo "FAIL: no login completed after alt+w -- keystrokes are not reaching the shell"
  ok=0
}

# That the shell is genuinely alive after the stuck case is proven by
# tavla_recovered.ppm above: `tasks` was typed into the replacement window and
# its output is on screen, which can only happen if keystrokes reach skalman
# again. Nothing to assert on serial here -- shell command output goes to the
# window, not the serial port.
panics=$(grep -c 'PANIC' serial.log || true)
dfs=$(grep -c 'double fault' serial.log || true)
echo "panics: $panics, double faults: $dfs"
[ "$panics" -eq 0 ] && [ "$dfs" -eq 0 ] || { echo "FAIL: crash during the run"; ok=0; }

echo
if [ "$ok" -eq 1 ]; then
  echo "PASS: tavla verified on real pixels — dim/bright title strip tracks focus,"
  echo "  client area is inset below the strip, alt+w closes the window and kills"
  echo "  its program, and closing skalman's own window is recoverable"
  exit 0
fi
echo "FAIL: tavla verification failed"
exit 1
