#!/usr/bin/env bash
#
# verify_skrift_run.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# skrift's F6 and F5, which run what is being written.
#
#   1. F6 on `6 * 7` builds it with coff and smed in the background, runs it
#      and the program it made ends with 42. F6 on `nope + 1` does not
#      compile, and coff's own message reaches the serial line, since the
#      background programs print there only.
#   1b. F6 on code that never ends stops it after three seconds, and skrift
#      goes on working.
#   2. F5 saves the file and runs `execute` on it in a new shell window, so
#      the program prints its line and ends with 5.
#   3. F6 removes the three files it made, so `list` shows none of them.
#   4. F5 with the second of two lines selected runs only that line, as
#      main's body, so it prints and ends with 6, never 9.
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

sockfile=verify_skrift_run.sock
rm -f serial.log "$sockfile" skrift_run*.ppm
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
def typ(keys, gap=0.08):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)
def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash", ";": "semicolon",
              "*": "shift-8", "+": "shift-equal", "(": "shift-9", ")": "shift-0",
              "{": "shift-bracket_left", "}": "shift-bracket_right",
              '"': "shift-apostrophe", "\\": "backslash"}
    typ([keymap.get(c, c) for c in s])

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("make w"); typ(["ret"]); time.sleep(0.4)
word("change w"); typ(["ret"]); time.sleep(0.4)
word("edit calc.c0"); typ(["ret"]); time.sleep(3.0)
word("6 * 7"); typ(["f6"]); time.sleep(8.0)
send("screendump skrift_run_value.ppm", settle=0.8)
typ(["ctrl-a"]); word("nope + 1"); typ(["f6"]); time.sleep(6.0)
typ(["ctrl-a"]); word("while (1) { } return 1"); typ(["f6"]); time.sleep(10.0)
typ(["ctrl-a"]); word('int main() { print("ran from skrift\\n"); return 5; }')
typ(["f5"]); time.sleep(10.0)
send("screendump skrift_run_f5.ppm", settle=0.8)
word("list"); typ(["ret"]); time.sleep(1.0)
# Back to skrift, by closing the shell window F5 opened (so there is room
# for another) and clicking in skrift, then F5 on the second of two lines,
# selected.
word("close"); typ(["ret"]); time.sleep(1.0)
for _ in range(12):
    send("mouse_move -100 -100", settle=0.04)
for _ in range(7):
    send("mouse_move 100 20", settle=0.04)
send("mouse_button 1", settle=0.3)
send("mouse_button 0", settle=0.5)
typ(["ctrl-a"]); word("return 9;"); typ(["ret"])
word('print("only the selection\\n"); return 6;')
typ(["shift-home"]); typ(["f5"]); time.sleep(10.0)
sock.close()
EOF2
sleep 1

ok=1
check() { # description, extended regex
  if grep -aqE "$2" serial.log; then echo "ok    $1"; else echo "FAIL  $1"; ok=0; fi
}
check "F6 on 6 * 7 ran a program that ended with 42" '^\[syscall\] exit code=42$'
check "F6 on nope + 1 got coff's own message" "undeclared variable 'nope'"
check "F6 on a loop that never ends stopped it after three seconds" '^\[syscall\] task [0-9]+ stopped task [0-9]+$'
check "F5 opened a shell window running execute" '^\[syscall\] shell execute calc\.c0 in window [0-9]+$'
check "the program F5 built printed its line" 'ran from skrift'
check "and ended with 5" '^\[syscall\] exit code=5$'
check "list ran in the shell window" '^\[sh\] .*calc\.c0'
check "F5 on a selection ran it" 'only the selection'
check "and ended with 6" '^\[syscall\] exit code=6$'
if grep -aq '^\[syscall\] exit code=9$' serial.log; then echo "FAIL  the line outside the selection ran"; ok=0; fi
if grep -aq 'skrift-eval' <(grep -a '^\[sh\]' serial.log); then
  echo "FAIL  F6 left its files behind"; ok=0
else
  echo "ok    F6 removed its files"
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: skrift's F6 worked out a value and F5 ran the file"
  exit 0
fi
echo "--- serial ---"
grep -aE '^\[(sh|syscall|elf)\]|coff|smed' serial.log | tail -40
exit 1
