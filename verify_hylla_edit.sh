#!/usr/bin/env bash
#
# verify_hylla_edit.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# hylla opens source and pictures in the kernel's editors (SYS_EDIT).
#
#   1. A click on a .c0 file opens it in skrift, in a new window, with the
#      file's own bytes loaded.
#   2. Typed keys then go to skrift, not to hylla, so the new window really
#      has the focus, and quitting saves to the same file. After the quit the
#      window is a shell, which reads the file back.
#   3. A click on a .spr file opens it in pensel, in another new window.
#
# The folder holds exactly one of each, made from the shell, and hylla is
# opened on it. The icons are found by the colours only they use, the text
# icon's teal lines and the picture's orange square, and the pointer by its
# white, as in verify_hylla.sh.
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

sockfile=verify_hylla_edit.sock
rm -f serial.log "$sockfile" hedit_*.ppm
rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
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
time.sleep(0.3)
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
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash", ";": "semicolon"}
    typ([keymap.get(c, c) for c in s])
def shot(name):
    send("screendump %s" % name, settle=0.8)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("make ed"); typ(["ret"]); time.sleep(0.4)
word("write ed/hello.c0 int seven;"); typ(["ret"]); time.sleep(0.4)
word("write ed/pic.spr x"); typ(["ret"]); time.sleep(0.4)
word("start hylla.elf ed"); typ(["ret"]); time.sleep(4.0)
# start leaves the focus on the shell, and a click on an unfocused tile only
# focuses it.
typ(["alt-tab"]); time.sleep(1.0)

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
            if buf[i:i+3] == want]

def pointer(path):
    pts = find(path, (255, 255, 255))
    return min(pts) if pts else None

def move_to(tx, ty):
    for attempt in range(5):
        shot("hedit_ptr.ppm")
        p = pointer("hedit_ptr.ppm")
        if p is None:
            return
        dx, dy = tx - p[0], ty - p[1]
        if abs(dx) <= 2 and abs(dy) <= 2:
            return
        steps = max(abs(dx), abs(dy)) // 8 + 1
        for _ in range(steps):
            send("mouse_move %d %d" % (dx // steps, dy // steps), settle=0.03)
        time.sleep(0.3)

def click_icon(rgb, name, clicks=1):
    shot(name)
    pts = find(name, rgb)
    if not pts:
        print("no icon of colour %r in %s" % (rgb, name))
        return
    cx = sum(x for x, y in pts) // len(pts)
    cy = sum(y for x, y in pts) // len(pts)
    move_to(cx, cy)
    for _ in range(clicks):
        send("mouse_button 1", settle=0.2)
        send("mouse_button 0", settle=0.2)
        time.sleep(1.5)

click_icon((0x30, 0xa8, 0xa0), "hedit_text.ppm")
word("z"); typ(["esc"]); word("q"); time.sleep(0.8)
word("echo --file ed/hello.c0"); typ(["ret"]); time.sleep(0.8)
# skrift's window took the focus, so the first click only gives it back to
# hylla.
click_icon((0xe0, 0x80, 0x30), "hedit_pic.ppm", clicks=2)
shot("hedit_end.ppm")
sock.close()
EOF2
sleep 1

ok=1
check() { # description, extended regex
  if grep -aqE "$2" serial.log; then echo "ok    $1"; else echo "FAIL  $1"; ok=0; fi
}
check "a click on hello.c0 asks for skrift" '^\[syscall\] edit ed/hello\.c0 in window [0-9]+$'
check "skrift opened hello.c0 with its 10 bytes" '^\[skrift\] editing ed/hello\.c0 bytes=10$'
# z typed after the click, saved by the quit, read back by the shell in the
# same window. With the focus left on hylla, nothing would have been typed.
check "typed keys went to skrift and were saved" '^\[sh\] zint seven;$'
check "a click on pic.spr asks for pensel" '^\[syscall\] edit ed/pic\.spr in window [0-9]+$'
check "pensel opened pic.spr" '^\[pensel\] editing ed/pic\.spr loaded='
text_win=$(grep -aoE '^\[syscall\] edit ed/hello\.c0 in window [0-9]+' serial.log | grep -oE '[0-9]+$' | head -1)
pic_win=$(grep -aoE '^\[syscall\] edit ed/pic\.spr in window [0-9]+' serial.log | grep -oE '[0-9]+$' | head -1)
if [ -n "$text_win" ] && [ "$text_win" = "$pic_win" ]; then
  echo "FAIL  the two editors share window $text_win"; ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: hylla opened hello.c0 in skrift (window $text_win) and pic.spr in pensel (window $pic_win)"
  exit 0
fi
echo "--- serial ---"
grep -aE '^\[(syscall|skrift|pensel|sh)\]' serial.log | tail -30
exit 1
