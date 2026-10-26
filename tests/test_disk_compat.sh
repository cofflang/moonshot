#!/usr/bin/env bash
#
# test_disk_compat.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# A disk synced by an older jakel still loads.
#
# jakel's node table holds 128 nodes, where an older one held 32, so
# the table is 16 sectors long rather than 4 and file data starts at sector
# 17 rather than 5. The superblock records both numbers, and the
# loader reads them instead of assuming them. This writes a disk exactly
# as the 32-node jakel wrote one (a root directory and one file, old.txt),
# boots the current kernel on it and has the shell print the file.
#
# The disk is built here byte by byte rather than by booting an old kernel,
# because a fresh clone has no old kernel to boot. The layout is jakel.c0's
# Superblock and NodeEntry, little-endian int64 fields, 64 bytes a node, the
# name inline at +32.

set -u
cd "$(dirname "$0")/.."

./build.sh || exit 1
mkdir -p out && cd out

rm -f disk.img serial.log
python3 - <<'EOF'
import struct
img = bytearray(512 * 20480)
# Superblock, sector 0, "JAKELBK\0", version 1, 32 nodes, names up to 32,
# data from sector 5, one data sector.
img[0:8] = b"JAKELBK\0"
struct.pack_into("<qqqqq", img, 8, 1, 32, 32, 5, 1)
def node(i, kind, parent, size, name):
    off = 512 + i * 64
    struct.pack_into("<qqqq", img, off, kind, parent, size, len(name))
    img[off + 32:off + 32 + len(name)] = name
node(0, 2, 0, 0, b"/")                # the root directory
text = b"OldFormatOK"
node(1, 1, 0, len(text), b"old.txt")  # one file in it
img[5 * 512:5 * 512 + len(text)] = text
open("disk.img", "wb").write(img)
EOF


isodir=isoroot
rm -rf "$isodir"
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1

sockfile=disk_compat.sock
rm -f "$sockfile"
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.3)
def keys(text):
    for c in text:
        name = {" ": "spc", "\n": "ret", ".": "dot", "-": "minus"}.get(c, c)
        s.send(("sendkey %s\n" % name).encode())
        time.sleep(0.05)
keys("root\n"); time.sleep(1)
keys("\n"); time.sleep(1.2)
keys("echo --file old.txt\n"); time.sleep(1.5)
s.close()
EOF

ok=1
if grep -q '^\[jakel\] loaded 2 nodes from disk' serial.log; then
  echo "PASS: the 32-node disk loaded (2 nodes)"
else
  echo "FAIL: the 32-node disk did not load"
  grep '^\[jakel\]' serial.log
  ok=0
fi
if grep -q 'OldFormatOK' serial.log; then
  echo "PASS: old.txt read back from sector 5"
else
  echo "FAIL: old.txt's contents are not in the serial output"
  ok=0
fi
[ "$ok" -eq 1 ] && exit 0
exit 1
