#!/usr/bin/env bash
#
# test_shell_paths.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# The shell's write, echo --file and remove take paths, so "dir1/c.txt" is c.txt
# inside dir1, from wherever the shell is.
#
# Looking a name up as one plain name would make `write dir1/c.txt
# text` create a file literally called "dir1/c.txt" in the current directory
# and leave dir1/c.txt empty, and echo --file, which resolves the path, would then
# print nothing. remove resolves the same way. One boot.
#
#   make dir1, make dir1/c.txt, write dir1/c.txt pathok from the root,
#   echo --file dir1/c.txt (by path), change dir1 and echo --file c.txt
#   (proves the text is in the file inside dir1, not in a stray one),
#   change back, remove dir1/c.txt, echo --file dir1/c.txt again (must find
#   nothing now).
#
# echo --file prints the whole file, however long. about.html is about 1.5KB,
# more than the shell's 1008-byte buffer, so its last line only arrives if
# the file is read piece by piece.

set -u
cd "$(dirname "$0")/.."

./build.sh || exit 1

rm -f disk.img serial.log
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

mkdir -p out && cd out

isodir=isoroot
rm -rf "$isodir"
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1

sockfile=shell_paths.sock
qemu_pid=0
cleanup() { [ "$qemu_pid" -ne 0 ] && kill "$qemu_pid" 2>/dev/null; wait 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

boot() { # serial-log, then one shell command per argument
  local log=$1
  shift
  rm -f "$sockfile"
  qemu-system-x86_64 -cdrom moonshot.iso \
    -serial file:"$log" -display none -no-reboot -m 128 \
    -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
    -monitor unix:"$sockfile",server,nowait &
  qemu_pid=$!
  sleep 3
  python3 - "$sockfile" "$@" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.3)
def keys(text):
    # Lower case only, since a bare capital is not a key name QEMU knows.
    for c in text:
        name = {" ": "spc", "\n": "ret", ".": "dot", "-": "minus", "/": "slash"}.get(c, c)
        s.send(("sendkey %s\n" % name).encode())
        time.sleep(0.05)
keys("root\n"); time.sleep(1)
keys("\n"); time.sleep(1.2)
for cmd in sys.argv[2:]:
    keys(cmd + "\n")
    time.sleep(1.0)
time.sleep(1)
s.close()
EOF
  kill "$qemu_pid" 2>/dev/null
  wait "$qemu_pid" 2>/dev/null
  qemu_pid=0
}

boot serial.log "make dir1" "make dir1/c.txt" "write dir1/c.txt pathok" \
  "echo --file dir1/c.txt" "change dir1" "echo --file c.txt" "change .." \
  "remove dir1/c.txt" "echo --file dir1/c.txt" "echo --file about.html"

hits=$(grep -c '^\[echo\] pathok' serial.log)
echo "pathok read back $hits times (expected 2: by path, then from inside dir1)"
tail_hits=$(grep -c 'Back to the first page</a>, the long way' serial.log)
echo "about.html's last link printed $tail_hits times (expected at least 1)"
if [ "$hits" -ne 2 ]; then
  echo "FAIL: the shell does not handle dir/file paths"
  exit 1
fi
if [ "$tail_hits" -lt 1 ]; then
  echo "FAIL: echo --file stops before the end of a long file"
  exit 1
fi
echo "PASS: write and echo --file follow dir1/c.txt, remove takes it away, and a long file prints whole"
exit 0
