#!/usr/bin/env bash
#
# verify_hylla.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# hylla, the file manager (programs/hylla/hylla.c0), driven by the mouse.
#
#   1. The background comes from hylla.bg, written from the shell first as a
#      colour, and fills most of hylla's window.
#   2. A click on the test folder enters it, and the path bar then reads
#      "test", pixel for pixel against the kernel font.
#   3. Backspace goes back up, and the path bar is empty again.
#   4. t shows the tree, whose top bar label then reads "icons", and a
#      click on the folder's row opens it, so rows one level deeper appear.
#   5. A click on that label goes back to the shelf, which now shows the
#      folder clicked in the tree, its path bar reading "test".
#   6. A click on the first page (index.html, the first .html in the root)
#      opens it in utsikt, whose address strip then reads "/index.html".
#
# Icons are found by the colours only they use, the folder's yellow and a
# page's blue lines, and the pointer by its white, as in
# verify_utsikt_script.sh.

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

sockfile=verify_hylla.sock
rm -f serial.log "$sockfile" hylla_*.ppm
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
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash", "#": "shift-3"}
    typ([keymap.get(c, c) for c in s])
def shot(name):
    send("screendump %s" % name, settle=0.8)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("write hylla.bg #304050"); typ(["ret"]); time.sleep(0.6)
word("start hylla.elf"); typ(["ret"]); time.sleep(4.0)
typ(["alt-tab"]); time.sleep(1.0)
shot("hylla_root.ppm")

def load(path):
    data = open(path, "rb").read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace(): pos += 1
        start = pos
        while not data[pos:pos+1].isspace(): pos += 1
        fields.append(int(data[start:pos]))
    return fields[0], fields[1], data[pos+1:]

def find(path, rgb):
    w, h, buf = load(path)
    want = bytes(rgb)
    return [((i // 3) % w, (i // 3) // w) for i in range(0, w * h * 3, 3)
            if buf[i:i+3] == want and (i // 3) % w >= w // 2]

def pointer(path):
    pts = find(path, (255, 255, 255))
    return min(pts) if pts else None

def move_to(tx, ty):
    for attempt in range(5):
        shot("hylla_ptr.ppm")
        p = pointer("hylla_ptr.ppm")
        if p is None:
            return
        dx, dy = tx - p[0], ty - p[1]
        if abs(dx) <= 2 and abs(dy) <= 2:
            return
        steps = max(abs(dx), abs(dy)) // 8 + 1
        for _ in range(steps):
            send("mouse_move %d %d" % (dx // steps, dy // steps), settle=0.03)
        time.sleep(0.3)

def click_cluster(path, rgb, first=True):
    pts = find(path, rgb)
    if not pts:
        return False
    # The top-left icon of this colour, its pixels within 40 of the first one.
    top = min(pts, key=lambda p: (p[1] // 40, p[0]))
    near = [p for p in pts if abs(p[0] - top[0]) < 40 and abs(p[1] - top[1]) < 40]
    cx = sum(x for x, y in near) // len(near)
    cy = sum(y for x, y in near) // len(near)
    move_to(cx, cy)
    send("mouse_button 1", settle=0.2)
    send("mouse_button 0", settle=0.2)
    time.sleep(1.0)
    return True

click_cluster("hylla_root.ppm", (0xd8, 0xa8, 0x50))
shot("hylla_test.ppm")
typ(["backspace"]); time.sleep(1.0)
shot("hylla_back.ppm")

# The tree. Its rows are 18 pixels apart, too close for click_cluster, so the
# first folder row is taken as the yellow pixels within a row of the topmost.
typ(["t"]); time.sleep(1.0)
shot("hylla_tree.ppm")
yellow = find("hylla_tree.ppm", (0xd8, 0xa8, 0x50))
if yellow:
    top = min(y for x, y in yellow)
    row = [p for p in yellow if p[1] < top + 12]
    move_to(sum(x for x, y in row) // len(row), sum(y for x, y in row) // len(row))
    send("mouse_button 1", settle=0.2)
    send("mouse_button 0", settle=0.2)
    time.sleep(1.0)
shot("hylla_tree_open.ppm")
# The view label, the dim text at the right end of the top bar.
w, h, buf = load("hylla_tree_open.ppm")
dim = [p for p in find("hylla_tree_open.ppm", (0x88, 0x90, 0xa0)) if p[0] >= w * 3 // 4]
if dim:
    top = min(y for x, y in dim)
    lab = [p for p in dim if p[1] < top + 10]
    move_to(sum(x for x, y in lab) // len(lab), sum(y for x, y in lab) // len(lab))
    send("mouse_button 1", settle=0.2)
    send("mouse_button 0", settle=0.2)
    time.sleep(1.0)
    # Off the label, which the pointer would otherwise cover.
    for _ in range(10): send("mouse_move -12 8", settle=0.03)
    time.sleep(0.5)
shot("hylla_shelf.ppm")
typ(["backspace"]); time.sleep(1.0)
shot("hylla_back2.ppm")
click_cluster("hylla_back2.ppm", (0x30, 0x70, 0xd0))
time.sleep(4.0)
shot("hylla_opened.ppm")

sock.close()
EOF2
sleep 1

python3 - <<'PY'
import re, sys
path, punkt = "hylla_root.ppm", "../kernel/screen/punkt.c0"
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
TEXT, DIM = (0xe0, 0xe4, 0xe8), (0x88, 0x90, 0xa0)
w, h, buf = read_ppm("hylla_root.ppm")
bg = pixels((0x30, 0x40, 0x50), w // 2)
print("1. hylla.bg's colour fills %d pixels of the right half" % len(bg))
if len(bg) < (w // 2) * h // 2:
    print("FAIL: the background is not the colour hylla.bg names"); ok = False
def bar_text(path):
    global w, h, buf
    w, h, buf = read_ppm(path)
    # The path bar is the window's top 16 rows below kakel's title strip.
    px = pixels(TEXT, w // 2)
    top = min((y for x, y in pixels((0x10, 0x18, 0x20), w // 2)), default=0)
    return {(x, y) for x, y in px if top <= y < top + 16}
t = bar_text("hylla_test.ppm")
if not t:
    print("FAIL: the path bar is empty after clicking the folder"); ok = False
else:
    m = matches(t, "test")
    print("2. after the click the path bar reads 'test': %s" % ("exact" if m[0] else "%d missing, %d extra" % (m[1], m[2])))
    if not m[0]: ok = False
b = bar_text("hylla_back.ppm")
print("3. after Backspace the path bar has %d text pixels" % len(b))
if b: print("FAIL: Backspace did not go back up to the root"); ok = False
def label(path):
    global w, h, buf
    w, h, buf = read_ppm(path)
    top = min((y for x, y in pixels((0x10, 0x18, 0x20), w // 2)), default=0)
    return {(x, y) for x, y in pixels(DIM, w * 3 // 4) if top <= y < top + 16}
def depth_pixels(path, x0):
    # Tree icon pixels (folder yellow, paper white) in the column one level
    # deeper than the rows at x0.
    global w, h, buf
    w, h, buf = read_ppm(path)
    px = pixels((0xd8, 0xa8, 0x50), w // 2) | pixels((0xe8, 0xe8, 0xe4), w // 2)
    return [p for p in px if x0 + 16 <= p[0] < x0 + 28]
l = label("hylla_tree.ppm")
m = matches(l, "icons") if l else (False, 0, 0)
print("4. after t the view label reads 'icons': %s" % ("exact" if m[0] else "%d missing, %d extra" % (m[1], m[2])))
if not m[0]: ok = False
w, h, buf = read_ppm("hylla_tree.ppm")
folders = pixels((0xd8, 0xa8, 0x50), w // 2)
if not folders:
    print("FAIL: no folder row in the tree"); ok = False
else:
    x0 = min(x for x, y in folders)
    before = len(depth_pixels("hylla_tree.ppm", x0))
    after = len(depth_pixels("hylla_tree_open.ppm", x0))
    print("   icon pixels one level deeper, before the click %d, after %d" % (before, after))
    if before != 0 or after == 0:
        print("FAIL: a click on the folder row did not open it in the tree"); ok = False
l = label("hylla_shelf.ppm")
m = matches(l, "tree") if l else (False, 0, 0)
print("5. after a click on the label it reads 'tree': %s" % ("exact" if m[0] else "%d missing, %d extra" % (m[1], m[2])))
if not m[0]: ok = False
t = bar_text("hylla_shelf.ppm")
m = matches(t, "test") if t else (False, 0, 0)
print("   and the shelf shows the folder from the tree, 'test': %s" % ("exact" if m[0] else "%d missing, %d extra" % (m[1], m[2])))
if not m[0]: ok = False
w, h, buf = read_ppm("hylla_opened.ppm")
fg = pixels((0xd0, 0xd0, 0xc8), 0)
if not fg:
    print("FAIL: no utsikt address strip after clicking the page"); ok = False
else:
    m = matches(fg, "/index.html")
    print("6. the page opened in utsikt, whose strip reads '/index.html': %s" % ("exact" if m[0] else "%d missing, %d extra" % (m[1], m[2])))
    if not m[0]: ok = False
sys.exit(0 if ok else 1)
PY
rc=$?
panics=$(grep -c 'PANIC' serial.log || true)
[ "$panics" -eq 0 ] || { echo "FAIL: kernel panic"; rc=1; }

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: hylla shows its background, enters and leaves folders, opens one in the tree, and opens a page"
  exit 0
fi
echo "FAIL: see above"
exit 1
