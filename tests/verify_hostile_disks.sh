#!/usr/bin/env bash
#
# verify_hostile_disks.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Boots the kernel on corrupted jakel disk images and checks that it neither
# panics nor hangs. The images come from tests/gen_hostile_disks.py and follow
# the hostile disk format specification. They are truncated images, directory
# loops, oversized lengths and unterminated names.
#
#   tests/verify_hostile_disks.sh            the cases that hold, in the suite
#   tests/verify_hostile_disks.sh known      the open findings, not in the suite
#   tests/verify_hostile_disks.sh case NAME...   the named cases, one boot each
#
# A case holds when the boot gets past the filesystem and the scheduler and
# the timer is still counting at tick 100 within the time limit, and the log
# shows no panic, no fault and no out-of-memory stop.
# The cases in KNOWN each expose a known open finding. They are listed
# below with the finding they show and are not run by the suite, since they
# stop or stall the kernel. A KNOWN case satisfying the acceptance checks is
# a classification error and makes the script exit 1. The cases in
# KNOWN_SILENT expose an open finding the boot log cannot see, so they are
# kept out of the suite too and known mode only reports them.
#
# Every image lives in out/hostile_disks, which is removed on exit. QEMU is
# given only those copies, never a real device.
set -u
cd "$(dirname "$0")/.."

LIMIT=${HOSTILE_DISK_LIMIT:-40}
DONE='^tick 100$'
FAULTS='PANIC|double fault|page fault|general protection|out of memory'

# The boot's own demand-paging self-test prints one page fault line for the
# 5GB sentinel page and recovers from it, so that line is not a stop.
faults() {
  grep -aE "$FAULTS" "$1" 2>/dev/null |
    awk '$0 == "page fault: addr=5368709120 errcode=0" && !seen++ { next } { print }'
}

# case name, finding, what the case shows
KNOWN=(
  "big_size_int64_max J-02 a file size of 2^63 - 1 overflows the arena request and stops the kernel with a general protection fault at boot"
  "parent_far_outside J-01 a parent id far outside the node table makes the loader read and write wild kernel addresses"
  "root_is_file J-04 a node 0 of type file is walked as the root directory, its bytes read as child ids"
  "file_named_test J-05 a file named test in the root is walked as a directory at boot, its bytes read as child ids"
)

# Cases that expose an open finding without a fault or a hang, so the boot
# looks the same whether the finding is open or fixed. They stay out of the
# suite, since a pass there would read as evidence about the finding. Known
# mode boots them and prints the outcome, but neither a hold nor a stop is a
# failure, and the finding has to be checked by hand when it is fixed.
KNOWN_SILENT=(
  "parent_negative J-01 a parent of -1 makes jakel_add_child load and store at 8 bytes below the size and data arrays, over the allocator headers, which the boot log cannot show"
)

all=$(python3 tests/gen_hostile_disks.py list) || exit 1

is_silent() { local k; for k in "${KNOWN_SILENT[@]}"; do [ "${k%% *}" = "$1" ] && return 0; done; return 1; }
is_known() { local k; for k in "${KNOWN[@]}"; do [ "${k%% *}" = "$1" ] && return 0; done; is_silent "$1"; }
finding_of() { local k; for k in "${KNOWN[@]}" "${KNOWN_SILENT[@]}"; do [ "${k%% *}" = "$1" ] && { echo "$k" | cut -d' ' -f2; return; }; done; }

mode=suite
names=()
case "${1:-}" in
  known) mode=known; for k in "${KNOWN[@]}" "${KNOWN_SILENT[@]}"; do names+=("${k%% *}"); done ;;
  case) mode=case; shift; names=("$@") ;;
  "") for n in $all; do is_known "$n" || names+=("$n"); done ;;
  *) echo "usage: $0 [known | case NAME...]"; exit 2 ;;
esac
if [ "${#names[@]}" -eq 0 ]; then echo "FAIL: no cases to run"; exit 1; fi
for n in "${names[@]}"; do
  case " $(echo $all) " in *" $n "*) ;; *) echo "FAIL: no such case $n"; exit 2 ;; esac
done

./build.sh || exit 1

scratch=out/hostile_disks
rm -rf "$scratch"
mkdir -p "$scratch/isoroot/boot/grub"
cp build/moonshot.elf "$scratch/isoroot/boot/moonshot.elf"
cp kernel/core/grub_test.cfg "$scratch/isoroot/boot/grub/grub.cfg"
grub-mkrescue -o "$scratch/moonshot.iso" "$scratch/isoroot" >"$scratch/grub-mkrescue.log" 2>&1
if [ ! -f "$scratch/moonshot.iso" ]; then
  echo "FAIL: grub-mkrescue did not produce an iso"
  cat "$scratch/grub-mkrescue.log"
  exit 1
fi
python3 tests/gen_hostile_disks.py "$scratch" "${names[@]}" || exit 1

qemu_pid=
cleanup() {
  [ -n "$qemu_pid" ] && { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }
  [ -n "${KEEP_HOSTILE_DISKS:-}" ] || rm -rf "$scratch"
}
trap cleanup EXIT

# Boots one image and sets how to done, fault or hang.
boot() { # name
  local log=$scratch/$1.log t0
  rm -f "$log"
  qemu-system-x86_64 -cdrom "$scratch/moonshot.iso" \
    -drive file="$scratch/$1.img",format=raw,if=ide,index=0,media=disk \
    -serial file:"$log" -display none -no-reboot -m 128 &
  qemu_pid=$!
  how=hang
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$LIMIT" ]; do
    if [ -n "$(faults "$log")" ]; then how=fault; break; fi
    if grep -aqE "$DONE" "$log" 2>/dev/null; then how=done; break; fi
    kill -0 "$qemu_pid" 2>/dev/null || { how=exited; break; }
    sleep 0.25
  done
  kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; qemu_pid=
}

ok=1
held=0
for n in "${names[@]}"; do
  boot "$n"
  log=$scratch/$n.log
  fault=$(faults "$log" | head -1)
  holds=no
  [ "$how" = done ] && [ -z "$fault" ] && holds=yes
  case "$mode" in
    suite|case)
      if [ "$holds" = yes ]; then
        echo "PASS: $n"
        held=$((held + 1))
      else
        echo "FAIL: $n, boot $how, ${fault:-no fault line}"
        tail -n 3 "$log"
        ok=0
      fi ;;
    known)
      echo "case $n ($(finding_of "$n")): boot $how, ${fault:-no fault line}"
      if is_silent "$n"; then
        echo "  silent finding, the boot cannot show it, check $(finding_of "$n") by hand"
      elif [ "$holds" = yes ]; then
        echo "  now holds, move it out of KNOWN"; ok=0
      elif [ "$how" != fault ] || ! grep -aq '^\[ata\] drive detected$' "$log"; then
        echo "  FAIL: no disk-stage kernel fault confirms the known finding"; ok=0
      fi ;;
  esac
done
[ "$mode" = known ] || echo "$held/${#names[@]} hostile disk images survived"
[ "$ok" -eq 1 ] || exit 1
exit 0
