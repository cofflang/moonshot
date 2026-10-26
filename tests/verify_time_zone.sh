#!/usr/bin/env bash
#
# verify_time_zone.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# The clock's offset survives a reboot. The first boot writes tid.zone, as a person
# would, and syncs it to disk. The second boot, from the same disk, reads it
# and says so before anyone logs in.
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
[ -f moonshot.iso ] || { echo "FAIL: grub-mkrescue did not produce moonshot.iso"; exit 1; }

disk=time_zone.img
rm -f "$disk"
dd if=/dev/zero of="$disk" bs=512 count=20480 2>/dev/null
boot() { # serial log, then keys typed one line at a time
  local log=$1
  shift
  rm -f "$log" time_zone.sock
  qemu-system-x86_64 -cdrom moonshot.iso -serial file:"$log" -display none -no-reboot -m 128 \
    -drive file="$disk",format=raw,if=ide,index=0,media=disk \
    -monitor unix:time_zone.sock,server,nowait &
  local pid=$!
  sleep 3
  python3 - "$@" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect("time_zone.sock"); time.sleep(0.2); s.recv(9999)
def k(x):
    s.sendall(("sendkey %s\n" % x).encode()); time.sleep(0.07); s.recv(9999)
m = {".": "dot", " ": "spc", "/": "slash", "+": "shift-equal"}
for line in sys.argv[1:]:
    for c in line: k(m.get(c, c))
    k("ret"); time.sleep(1.0)
PY
  sleep 1
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
}
boot first.log root "" "write tid.zone +120" "sync"
boot second.log

ok=1
if grep -aq '^\[clock\] utc=[0-9]* offset=0 min$' first.log; then
  echo "  ok   the first boot starts at UTC"
else
  echo "  FAIL the first boot did not start at offset 0"; ok=0
fi
if grep -aq '^\[jakel\] synced' first.log; then echo "  ok   tid.zone synced"; else echo "  FAIL nothing was synced"; ok=0; fi
if grep -aq '^\[clock\] utc=[0-9]* offset=120 min$' second.log; then
  echo "  ok   the second boot read the offset back"
else
  echo "  FAIL the second boot says: $(grep -a '^\[clock\]' second.log)"; ok=0
fi
if [ "$ok" -eq 1 ]; then echo "PASS: tid.zone survives a reboot"; exit 0; fi
exit 1
