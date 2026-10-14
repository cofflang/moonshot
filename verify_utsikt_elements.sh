#!/usr/bin/env bash
#
# verify_utsikt_elements.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# utsikt's less common HTML elements, on test/elements.html
# (seeded by the kernel, index_html.c0), opened with
# `start utsikt.elf test/elements.html`. The page gives every element it
# checks a colour of its own, so each one is found on the screen by colour.
#
#   1. <pre> keeps its line break and the four spaces in front of the second
#      line, which sits exactly four cells further right.
#   2. <ol> numbers its items. Each line reads "1. one", "2. two" and
#      "3. three", pixel for pixel against the kernel font.
#   3. <u> and <s> draw a line under and through their words, spaces
#      included, as long as the text.
#   4. <h4> is a block on a line of its own and <mark> has a background.
#   5. A <script>'s contents are raw text. Its string holds "</div>", and
#      the text after the script is still inside the <div> around it.

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

sockfile=verify_utsikt_elements.sock
rm -f serial.log "$sockfile" elements.ppm
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
word("start utsikt.elf test/elements.html"); typ(["ret"]); time.sleep(4.0)
shot("elements.ppm")

sock.close()
EOF2
sleep 1

python3 - <<'PY'
import re, sys
path, punkt = "elements.ppm", "punkt.c0"
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
# 1. pre
pre = lines(pixels((0xa0, 0x10, 0x10), half))
print("pre lines: %d" % len(pre))
if len(pre) != 2:
    print("FAIL: <pre> did not keep its two lines"); ok = False
else:
    a, b = pre
    for px, t in ((a, "AB"), (b, "CD")):
        m = matches(px, t)
        if not m[0]: print("FAIL: <pre> line is not %r (%d missing, %d extra)" % (t, m[1], m[2])); ok = False
    shift = min(x for x, y in b) - min(x for x, y in a)
    want_shift = min(x for x, y in render("    CD")) - min(x for x, y in render("AB"))
    print("pre: second line %d px right of the first, %d expected" % (shift, want_shift))
    if shift != want_shift: print("FAIL: <pre> lost its leading spaces"); ok = False
# 2. ol
ol = lines(pixels((0x10, 0x40, 0xa0), half))
print("ol lines: %d" % len(ol))
texts = ["1. one", "2. two", "3. three"]
if len(ol) != 3:
    print("FAIL: expected three numbered items"); ok = False
else:
    for px, t in zip(ol, texts):
        m = matches(px, t)
        print("  %r: %s" % (t, "exact" if m[0] else "%d missing, %d extra" % (m[1], m[2])))
        if not m[0]: ok = False
# 3. underline and strike
def longest_run(px):
    best = 0
    rows = {}
    for x, y in px: rows.setdefault(y, set()).add(x)
    for y, xs in rows.items():
        run = 0
        for x in range(min(xs), max(xs) + 2):
            run = run + 1 if x in xs else 0
            best = max(best, run)
    return best
u = pixels((0x10, 0x80, 0x10), half); s = pixels((0x80, 0x60, 0x00), half)
print("underline run %d, strike run %d (text %d and %d px wide)" % (longest_run(u), longest_run(s), 11 * 8, 10 * 8))
if longest_run(u) < 11 * 8 - 2: print("FAIL: <u> is not underlined across its words"); ok = False
if longest_run(s) < 10 * 8 - 2: print("FAIL: <s> is not struck through across its words"); ok = False
# 4. h4 and mark and script
h4 = pixels((0xa0, 0x00, 0xa0), half)
mark = pixels((0xf0, 0xe0, 0x60), half)
js = pixels((0xff, 0x00, 0x00), half)
print("h4 %d, mark %d, script-red %d" % (len(h4), len(mark), len(js)))
if len(h4) < 50: print("FAIL: no <h4>"); ok = False
elif u and min(y for x, y in h4) <= max(y for x, y in u): print("FAIL: <h4> is not on a line of its own"); ok = False
if len(mark) < 100: print("FAIL: <mark> has no background"); ok = False
box = pixels((0x00, 0x60, 0xc0), half)
print("text after the script, still in its box: %d pixels" % len(box))
if js: print("FAIL: markup inside <script> was parsed as HTML"); ok = False
if len(box) < 100: print("FAIL: a </div> inside a <script> string closed the box around it"); ok = False
sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: utsikt lays out pre, ol, u, s, h4, mark and keeps script text out"
  exit 0
fi
echo "FAIL: see above"
exit 1
