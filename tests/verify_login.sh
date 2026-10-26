#!/usr/bin/env bash
#
# verify_login.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# The login screen (raket.c0).
#
#   1. Before anyone logs in, typing reaches no shell, the screen takes it.
#   2. A wrong password is refused, and the screen says so in red. The
#      typing stays in the password field, and a click on the username
#      field moves it there.
#   3. root with its (empty) password opens the shell.
#   4. Alt+L locks the screen. Typing reaches no shell again, a wrong
#      password is refused, and root's password opens it.
#   5. A window opened after the last one is closed is root's shell, not a
#      second login, since the login is the machine's, not the window's.
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

sockfile=verify_login.sock
rm -f serial.log "$sockfile" login_*.ppm
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

python3 - "$sockfile" <<'PY'
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
sock.setblocking(False)
time.sleep(0.3)
def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    try:
        sock.recv(65536)
    except BlockingIOError:
        pass
def typ(keys, gap=0.08):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)
def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])
def shot(name):
    send("screendump %s" % name, settle=1.0)
    data = open(name, "rb").read()
    head = data.split(b"\n", 3)
    w, h = map(int, head[1].split())
    return w, h, head[3]
def count(img, rgb):
    w, h, d = img
    want = bytes(rgb)
    return sum(1 for i in range(0, len(d), 3) if d[i:i+3] == want)
RED = (255, 122, 106)
fails = []
def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)

# 1. Typed at the login screen, `where` would print / in a shell.
# Enter moves from the username to the password, and Enter there tries.
word("where"); typ(["ret"]); time.sleep(0.5)
word("x"); typ(["ret"]); time.sleep(1.0)
check(count(shot("login_wrong.ppm"), RED) > 50, "2. a wrong password is shown in red")
# The name stays and the password field has the focus, its frame orange. A
# click on the username field, 38 pixels above, moves the typing there, so
# the name can be cleared and root typed in its place. The pointer is found
# by its white, which nothing else on the lock screen is.
ORANGE, WHITE = (255, 180, 60), (255, 255, 255)
def where(img, rgb):
    w, h, d = img
    want = bytes(rgb)
    return [((i // 3) % w, (i // 3) // w) for i in range(0, len(d), 3) if d[i:i+3] == want]
frame = where(shot("login_focus.ppm"), ORANGE)
check(len(frame) > 0, "2. the focused field has an orange frame")
if frame:
    tx = (min(x for x, y in frame) + max(x for x, y in frame)) // 2
    ty = min(y for x, y in frame) - 38 + 7
    for attempt in range(5):
        ptr = where(shot("login_ptr.ppm"), WHITE)
        if not ptr: break
        px, py = min(ptr)
        dx, dy = tx - px, ty - py
        if abs(dx) <= 2 and abs(dy) <= 2: break
        steps = max(abs(dx), abs(dy)) // 8 + 1
        for _ in range(steps):
            send("mouse_move %d %d" % (dx // steps, dy // steps), settle=0.03)
        time.sleep(0.3)
    send("mouse_button 1", settle=0.2)
    send("mouse_button 0", settle=0.2)
    time.sleep(0.5)
    moved = where(shot("login_clicked.ppm"), ORANGE)
    check(bool(moved) and min(y for x, y in moved) == min(y for x, y in frame) - 38,
          "2. a click on the username field moves the orange frame there")
for _ in range(6): typ(["backspace"])
word("root"); typ(["ret", "ret"]); time.sleep(1.5)
word("echo one"); typ(["ret"]); time.sleep(0.6)
typ(["alt-l"]); time.sleep(1.0)
word("echo two"); typ(["ret"]); time.sleep(0.6)
typ(["ret"]); time.sleep(1.5)
word("echo three"); typ(["ret"]); time.sleep(0.6)
word("close"); typ(["ret"]); time.sleep(1.5)
word("echo four"); typ(["ret"]); time.sleep(0.8)
sock.close()
open("login_steps.result", "w").write("FAIL\n" if fails else "PASS\n")
PY
sleep 1

ok=1
[ "$(cat login_steps.result 2>/dev/null)" = "PASS" ] || ok=0
rm -f login_steps.result
log=$(grep -aE '^\[sh\] (/|one|two|three|four)$|screen (login|locked)' serial.log)
echo "$log"
first=$(echo "$log" | sed -n '0,/ok=1$/p')
if echo "$first" | grep -q '^\[sh\]'; then echo "FAIL 1. something reached a shell before the login"; ok=0; fi
if ! echo "$first" | grep -q "username='where' .* ok=0"; then
  echo "FAIL 2. the first attempt was not refused"; ok=0
fi
if ! echo "$log" | grep -q "username='root' uid=0 ok=1"; then echo "FAIL 3. root did not log in"; ok=0; fi
if ! grep -aq '^\[sh\] one$' serial.log; then echo "FAIL 3. the shell did not answer after the login"; ok=0; fi
if grep -aq '^\[sh\] two$' serial.log; then echo "FAIL 4. a key reached the shell while locked"; ok=0; fi
if ! grep -aq '^\[raket\] screen locked$' serial.log || ! grep -aq '^\[sh\] three$' serial.log; then
  echo "FAIL 4. Alt+L did not lock, or root's password did not open it"; ok=0
fi
if ! grep -aq '^\[sh\] four$' serial.log; then
  echo "FAIL 5. the window after close was not root's shell"; ok=0
fi
if [ "$ok" -eq 1 ]; then
  echo "PASS: the login screen guards the machine and the lock"
  exit 0
fi
exit 1
