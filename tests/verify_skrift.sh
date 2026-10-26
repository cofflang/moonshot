#!/usr/bin/env bash
#
# verify_skrift.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# skrift, the text editor, as a ring-3 program in a window, opened with the
# shell's edit from inside a folder. Everything is typed through QEMU's
# keyboard and checked in the file skrift saves, read back by the shell.
#
#   0. edit gives the new window the focus, and the file is found and saved
#      from the shell's folder, not from the root.
#   1. Typing types, Ctrl+Z takes back the last word only, Enter keeps the
#      line's indentation.
#   2. Ctrl+C on a selection and Ctrl+V paste it, Ctrl+X with nothing
#      selected cuts the whole line and Ctrl+V puts it back above the
#      cursor's line.
#   3. F3 finds a word and typing replaces it, F4 goes to a line, Ctrl+Z and
#      Ctrl+Y undo and redo.
#   4. F2 saves to the name skrift was started with (a file that did not
#      exist), Alt+W quits and closes the window.
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

sockfile=verify_skrift.sock
rm -f serial.log "$sockfile" skrift_*.ppm
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
              "!": "shift-1"}
    typ([keymap.get(c, c) for c in s])

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("make d"); typ(["ret"]); time.sleep(0.4)
word("change d"); typ(["ret"]); time.sleep(0.4)
word("edit notes.txt"); typ(["ret"]); time.sleep(3.0)

word("hello world"); typ(["ret"]); word("second"); typ(["ctrl-z"]); word("two")
typ(["ret"]); word("    indented"); typ(["ret"]); word("x")
typ(["ctrl-home", "shift-end", "ctrl-c", "ctrl-end", "ret", "ctrl-v"])
typ(["ctrl-home", "down", "ctrl-x", "ctrl-end", "ctrl-v"])
typ(["ctrl-home", "f3"]); word("world"); typ(["esc"]); word("moon")
typ(["f4"]); word("3"); typ(["ret", "end"]); word("!"); typ(["ctrl-z", "ctrl-y"])
time.sleep(0.5)
send("screendump skrift_edit.ppm", settle=0.8)
# Alt+W with unsaved changes asks first, and Esc keeps editing.
typ(["alt-w"]); time.sleep(0.3)
send("screendump skrift_ask.ppm", settle=0.8)
typ(["esc", "f2"]); time.sleep(0.5)
typ(["alt-w"]); time.sleep(1.5)
word("change .."); typ(["ret"]); time.sleep(0.4)
word("echo --file d/notes.txt"); typ(["ret"]); time.sleep(1.0)
sock.close()
EOF2
sleep 1

expected=$'hello moon\n    indented\n    x!\ntwo\n    hello world'
got=$(grep -a '^\[sh\] ' serial.log | sed 's/^\[sh\] //' | grep -A4 '^hello moon$' | head -5)
if [ "$got" = "$expected" ]; then
  echo "PASS: skrift typed, undid, pasted, found, went to a line and saved"
  exit 0
fi
echo "FAIL: the saved file reads"
printf '%s\n' "$got"
echo "--- expected ---"
printf '%s\n' "$expected"
echo "--- serial ---"
grep -aE '^\[(sh|syscall|elf|task)\]' serial.log | tail -25
exit 1
