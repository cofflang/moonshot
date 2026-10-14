#!/usr/bin/env bash
#
# verify_utsikt_script.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# utsikt's scripting interface (script.c0), driven by its test engine
# (engine_test.c0), on test/script.html (seeded by the kernel).
#
#   1. A <script type="text/x-utsikt-test"> runs when the page loads. It sets
#      a paragraph that says "before" to "after the script".
#   2. A <script> with no type and one typed text/javascript are claimed by
#      no engine and do not run, although their text is a test-engine
#      command.
#      The paragraph it would change still says "untouched".
#   3. A click on a block with an onclick attribute hands the attribute to
#      the page's engine. The test moves the pointer onto it and clicks, and
#      the paragraph then says "clicked" and the block "done".
#
# Every text is checked pixel for pixel against the kernel font, read out
# of punkt.c0, each found on the screen by a colour only it uses.

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

sockfile=verify_utsikt_script.sock
rm -f serial.log "$sockfile" script_*.ppm
[ -f disk.img ] || dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'EOF2'
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.2)
sock.recv(65536)
def send(cmd, settle=0.06):
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
def shot(name):
    send("screendump %s" % name, settle=0.8)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("start utsikt.elf test/script.html"); typ(["ret"]); time.sleep(4.0)
# Focus the browser, so the click below reaches the page rather than only
# focusing its window.
typ(["alt-tab"]); time.sleep(1.0)
shot("script_loaded.ppm")

def pointer(path):
    data = open(path, "rb").read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace(): pos += 1
        start = pos
        while not data[pos:pos+1].isspace(): pos += 1
        fields.append(int(data[start:pos]))
    w, h, buf = fields[0], fields[1], data[pos+1:]
    pts = [((i // 3) % w, (i // 3) // w) for i in range(0, w * h * 3, 3)
           if buf[i:i+3] == b"\xff\xff\xff"]
    return min(pts) if pts else None

def move_to(tx, ty):
    for attempt in range(4):
        shot("script_ptr.ppm")
        p = pointer("script_ptr.ppm")
        if p is None:
            return
        dx, dy = tx - p[0], ty - p[1]
        if abs(dx) <= 2 and abs(dy) <= 2:
            return
        steps = max(abs(dx), abs(dy)) // 8 + 1
        for _ in range(steps):
            send("mouse_move %d %d" % (dx // steps, dy // steps), settle=0.03)
        time.sleep(0.3)

# The block's middle, found from its background colour.
data = open("script_loaded.ppm", "rb").read()
fields, pos = [], 2
while len(fields) < 3:
    while data[pos:pos+1].isspace(): pos += 1
    start = pos
    while not data[pos:pos+1].isspace(): pos += 1
    fields.append(int(data[start:pos]))
w, h, buf = fields[0], fields[1], data[pos+1:]
blue = [((i // 3) % w, (i // 3) // w) for i in range(0, w * h * 3, 3)
        if buf[i:i+3] == bytes([0x20, 0x80, 0xc0])]
if blue:
    bx = (min(x for x, y in blue) + max(x for x, y in blue)) // 2
    by = (min(y for x, y in blue) + max(y for x, y in blue)) // 2
    move_to(bx, by)
    send("mouse_button 1", settle=0.3)
    send("mouse_button 0", settle=0.3)
    time.sleep(1.0)
shot("script_clicked.ppm")

sock.close()
EOF2
sleep 1

python3 - <<'PY'
import re, sys
path, punkt = "script_loaded.ppm", "punkt.c0"
def read_ppm(path):
    data = open(path, "rb").read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace(): pos += 1
        start = pos
        while not data[pos:pos+1].isspace(): pos += 1
        fields.append(int(data[start:pos]))
    return fields[0], fields[1], data[pos+1:]
w, h, buf = read_ppm(path)
def pixels(colour, x0=0):
    out = set()
    for i in range(0, w * h * 3, 3):
        if (buf[i], buf[i+1], buf[i+2]) == colour:
            x = (i // 3) % w
            if x >= x0: out.add((x, (i // 3) // w))
    return out
src = open(punkt).read()
def table(fn):
    body = src[src.index("int %s(int ch) {" % fn):]
    body = body[:body.index("\n}\n")]
    out = {}
    for key, val in re.findall(r"if \(ch == ('(?:\\.|.)'|\d+)\)\s*\{ return (0x[0-9A-Fa-f]+); \}", body):
        ch = int(key) if key[0] != "'" else ord(key[1:-1].replace("\\", ""))
        out[ch] = int(val, 16)
    return out
hi, lo = table("font_hi"), table("font_lo")
def render(text):
    lit = set()
    for k, ch in enumerate(text):
        for r in range(8):
            word = hi.get(ord(ch), 0) if r < 4 else lo.get(ord(ch), 0)
            bits = (word >> ((3 - r if r < 4 else 7 - r) * 8)) & 255
            for c in range(8):
                if (bits >> (7 - c)) & 1: lit.add((k * 8 + c, r))
    return lit
def lines(px):
    rows = {}
    for x, y in px: rows.setdefault(y // 1, []).append(x)
    ys = sorted(rows)
    groups, cur = [], []
    for y in ys:
        if cur and y - cur[-1] > 2: groups.append(cur); cur = []
        cur.append(y)
    if cur: groups.append(cur)
    return [{(x, y) for x, y in px if g[0] <= y <= g[-1]} for g in groups]
def matches(px, text):
    want = render(text)
    gx, gy = min(x for x, y in px), min(y for x, y in px)
    wx, wy = min(x for x, y in want), min(y for x, y in want)
    got = {(x - gx + wx, y - gy + wy) for x, y in px}
    return got == want, len(want - got), len(got - want)
ok = True
half = w // 2
def read_text(colour, path):
    global w, h, buf
    w, h, buf = read_ppm(path)
    return pixels(colour, w // 2)
def says(colour, path, text, label):
    px = read_text(colour, path)
    if not px:
        print("FAIL: %s shows nothing" % label)
        return False
    m = matches(px, text)
    print("%s reads %r: %s" % (label, text, "exact" if m[0] else "%d missing, %d extra" % (m[1], m[2])))
    return m[0]
OUT, KEEP, BTN = (0xc0, 0x20, 0x60), (0x20, 0xa0, 0x20), (0xff, 0xf0, 0xa0)
if not says(OUT, "script_loaded.ppm", "after the script", "the paragraph a script sets"): ok = False
if not says(KEEP, "script_loaded.ppm", "untouched", "the paragraph only JavaScript would set"): ok = False
if not says(BTN, "script_loaded.ppm", "click me", "the block"): ok = False
if not says(OUT, "script_clicked.ppm", "clicked", "after the click, the paragraph"): ok = False
if not says(BTN, "script_clicked.ppm", "done", "after the click, the block"): ok = False
if not says(KEEP, "script_clicked.ppm", "untouched", "after the click, the other paragraph"): ok = False
sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: scripts run through the engine that claims them, and onclick reaches it"
  exit 0
fi
echo "FAIL: see above"
exit 1
