#!/usr/bin/env bash
#
# verify_utsikt_descendant.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that utsikt's cascade honours a DESCENDANT selector, which is the
# first selector shape it has that looks anywhere except at the element
# being styled.
#
# /index.html carries both of these:
#
#     code      { color: #006060; }
#     .note code { color: #a03000; }
#
# and it has <code> elements in both positions -- two inside the
# <div class="note">, and more further down the page outside it. So one
# rendered page answers both halves of the question at once, and neither
# half alone would be convincing:
#
#   1. The rust colour must appear. If the ancestor test never matched, or
#      the rule were dropped as an unsupported selector, every <code> would
#      be teal and there would be no rust pixels anywhere.
#   2. The teal colour must ALSO appear. If the ancestor condition were
#      ignored and `.note code` were treated as plain `code`, every <code>
#      would be rust instead. A test that only looked for rust would pass
#      just as happily on that, which would be an engine with descendant
#      selectors that do not actually descend.
#
# Both <code> runs sit near the top of the document, so no scrolling is
# needed; the note is above the fold and the first bare <code> is a few
# lines below it.
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

sockfile=verify_utsikt_desc.sock
rm -f serial.log "$sockfile" udesc_*.ppm
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
    keymap = {".": "dot", " ": "spc", "-": "minus", "_": "shift-minus"}
    typ([keymap.get(c, c) for c in s])
def shot(name):
    send("screendump %s" % name, settle=0.9)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("spawn3 utsikt.elf"); typ(["ret"]); time.sleep(4.5)
shot("udesc_page.ppm")
sock.close()
EOF2

sleep 1

python3 - <<'PY'
import sys
INSIDE  = (160, 48, 0)     # .note code { color: #a03000 }
OUTSIDE = (0, 96, 96)      # code      { color: #006060 }

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
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

# Count inside the tavla only: it is the right half of the screen, and the
# shell beside it is not part of this question.
def counts(path):
    w, h, buf = read_ppm(path)
    x0 = w // 2
    ins = out = 0
    for y in range(h):
        row = y * w
        for x in range(x0, w):
            off = (row + x) * 3
            c = (buf[off], buf[off+1], buf[off+2])
            if c == INSIDE:
                ins += 1
            elif c == OUTSIDE:
                out += 1
    return ins, out

ins, out = counts("udesc_page.ppm")
print("rust pixels (code inside .note): %d" % ins)
print("teal pixels (code outside it):   %d" % out)

# Glyphs at this size are a few dozen pixels per run and there are several
# runs of each, so a real match is in the hundreds. The floor is set well
# below that and well above stray antialiasing, of which there is none --
# punkt draws no partial pixels, so every pixel is exactly one of the two.
FLOOR = 40
ok = True
if ins < FLOOR:
    print("FAIL: no rust <code> text. The descendant selector `.note code`")
    print("      did not apply, so either the ancestor walk never matched or")
    print("      the rule was dropped while parsing.")
    ok = False
if out < FLOOR:
    print("FAIL: no teal <code> text. Every <code> took the .note colour, so")
    print("      the ancestor half of `.note code` was ignored and it matched")
    print("      like a plain `code` selector.")
    ok = False
sys.exit(0 if ok else 1)
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo 'PASS: `.note code` styles only the <code> inside the note, and plain'
  echo '      <code> elsewhere keeps its own colour'
  exit 0
fi
echo "FAIL: see above"
exit 1
