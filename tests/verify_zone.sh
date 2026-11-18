#!/usr/bin/env bash
#
# verify_zone.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# The shell's zone command, with QEMU's clock started at 10:00:30 UTC.
#
#   1. A user who is not root sets the zone. zone -3:30 and zone +2 each
#      say the local time and the offset, and so does zone on its own.
#   2. zone 25, zone +1:60 and zone 2x are refused with the usage line and
#      leave the offset at +2.
#   3. The offset is saved in tid.zone, and the second boot, from the same
#      disk, reads +2 back.
#   4. With no disk, zone +3 still sets the offset and says it was not
#      saved.
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

disk=zone.img
rm -f "$disk"
dd if=/dev/zero of="$disk" bs=512 count=20480 2>/dev/null
python3 -c 'f = open("zone.img", "r+b"); f.write(b"JAKELBK\0"); f.close()'
# A boot that types its lines and then waits, up to a minute, until the
# shell has said the time and zone `want` times. Setting the zone saves the
# whole disk, which takes seconds, and a boot cut off halfway through a
# save leaves a disk the next one cannot read.
boot() { # serial log, zone lines to wait for, then keys typed one line at a time
  local log=$1 want=$2
  shift 2
  local drive=(-drive file="$disk",format=raw,if=ide,index=0,media=disk)
  [ "$log" = third.log ] && drive=()
  rm -f "$log" zone.sock
  qemu-system-x86_64 -cdrom moonshot.iso -serial file:"$log" -display none -no-reboot -m 128 \
    -rtc base=2026-10-15T10:00:30 \
    "${drive[@]}" \
    -monitor unix:zone.sock,server,nowait &
  local pid=$!
  sleep 3
  python3 - "$@" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect("zone.sock"); time.sleep(0.2); s.recv(9999)
def k(x):
    s.sendall(("sendkey %s\n" % x).encode()); time.sleep(0.07); s.recv(9999)
m = {".": "dot", " ": "spc", "/": "slash", "+": "shift-equal", "-": "minus", ":": "shift-semicolon"}
for line in sys.argv[1:]:
    for c in line: k(m.get(c, c))
    k("ret"); time.sleep(1.0)
PY
  local t=0
  while [ "$(grep -ac '^\[sh\] [0-9][0-9]:[0-9][0-9], UTC' "$log")" -lt "$want" ] && [ $t -lt 60 ]; do
    sleep 1; t=$((t + 1))
  done
  sleep 1
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
}
trap 'rm -f zone.sock' EXIT
boot first.log 3 root "" "adduser ada" "login ada" "" "whoami" \
  "zone -3:30" "zone +2" "zone 25" "zone +1:60" "zone 2x" "zone"
boot second.log 1 root "" "zone"
boot third.log 1 root "" "zone +3"
rm -f "$disk"

ok=1
check() { # log, what it shows, pattern
  if grep -aqE "$3" "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; ok=0; fi
}
check first.log "1. ada, not root, is the one typing" '^\[sh\] ada$'
check first.log "1. zone -3:30 says the time and UTC-3:30" '^\[sh\] 06:3[01], UTC-3:30$'
check first.log "1. zone +2 says the time and UTC+2" '^\[sh\] 12:0[01], UTC\+2$'
check first.log "1. the kernel took 120 minutes" '^\[clock\] offset set to 120 min$'
refused=$(grep -ac '^\[sh\] zone: usage: zone ' first.log)
[ "$refused" -eq 3 ] && echo "  ok   2. three inputs refused" || { echo "  FAIL 2. $refused of 3 inputs refused"; ok=0; }
sets=$(grep -ac '^\[clock\] offset set to' first.log)
[ "$sets" -eq 2 ] && echo "  ok   2. only the two good inputs set it" || { echo "  FAIL 2. the offset was set $sets times, not 2"; ok=0; }
last=$(grep -aE '^\[sh\] [0-9][0-9]:[0-9][0-9], UTC' first.log | tail -1)
case "$last" in
  *", UTC+2") echo "  ok   2. zone on its own still says UTC+2" ;;
  *) echo "  FAIL 2. the last zone said: ${last:-nothing}"; ok=0 ;;
esac
if sed -n '/^\[clock\] offset set to 120 min$/,$p' first.log | grep -aq '^\[jakel\] synced'; then
  echo "  ok   3. the disk was saved after the zone was set"
else
  echo "  FAIL 3. no save after the zone was set"; ok=0
fi
check second.log "3. the second boot read +2 back from tid.zone" '^\[clock\] utc=[0-9]* offset=120 min$'
check second.log "3. and zone says so" '^\[sh\] 12:0[01], UTC\+2$'
check third.log "4. zone +3 with no disk still sets the offset" '^\[sh\] 13:0[0-2], UTC\+3$'
check third.log "4. and says it was not saved" '^\[sh\] zone: set, but not saved, there is no disk$'
if [ "$ok" -eq 1 ]; then echo "PASS: zone shows and sets the offset, refuses bad input, and the offset survives a reboot"; exit 0; fi
grep -aE '^\[(sh|clock|jakel)\]' first.log second.log third.log | grep -v 'bounds\|prompt' | tail -30
exit 1
