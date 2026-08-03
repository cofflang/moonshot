#!/usr/bin/env bash
#
# test_panic.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Verifies the fatal-exception panic path by deliberately triggering a real
# divide-by-zero (#DE, vector 0) and checking the generic panic_handler
# prints its diagnostic instead of the kernel silently triple-faulting.
#
# The panic HANDLERS themselves ship in the normal kernel (installed for
# #0/#6/#13 in main(), knekt.c0); only the fault TRIGGER is test-only, so
# production code is never polluted with a deliberate bug. Because every
# fixed-slot address is hardcoded in kmain.c0/sync_addrs.sh's targets and
# injecting the fault changes the compiled size (shifting those addresses),
# this temporarily edits knekt.c0 (where kernel_post_init actually lives,
# since Moonshot's kernel code got split across subsystem files -- see
# kmain.c0's own comment), re-syncs the addresses via sync_addrs.sh,
# builds+boots that variant, then ALWAYS restores the pristine knekt.c0 --
# a trap guarantees restoration even if the build or boot fails midway.
set -u
cd "$(dirname "$0")"

cp knekt.c0 knekt.c0.panicbak
restore() {
  if [ -f knekt.c0.panicbak ]; then
    mv -f knekt.c0.panicbak knekt.c0
    ./sync_addrs.sh >/dev/null 2>&1 || true
  fi
}
trap restore EXIT

# Inject a runtime divide-by-zero as the first statements of
# kernel_post_init (which boot.s calls after lidt, so the #DE handler is
# live). panic_z is a real variable so coff (neither coff1, the compiler
# that actually builds Moonshot, nor coff0.c, its differential-testing
# oracle -- verified byte-identical between the two) does any constant
# folding of 1/panic_z at compile time -- the idiv executes with a zero
# divisor and raises #DE. The python script asserts its target marker is
# actually found (not a silent no-op if the source ever moves again) --
# `set -e` isn't used in this script, so an unhandled Python exception is
# what actually stops the script here, same as any other command failure.
python3 - <<'PY'
p = 'knekt.c0'
s = open(p).read()
marker = 'void kernel_post_init() {\n'
inject = ('    int panic_z = 0;\n'
          '    serial_print("panic test: forcing divide by zero\\n");\n'
          '    int panic_x = 1 / panic_z;\n')
assert marker in s, "kernel_post_init marker not found in knekt.c0"
open(p, 'w').write(s.replace(marker, marker + inject, 1))
PY

if ! ./sync_addrs.sh >/dev/null 2>&1; then
  # sync_addrs may need a second pass if the first one shifted addresses
  # (the fixed-width-immediate assumption can break when injection changes
  # .text size and JIT helper addresses are patched from 0 to their real
  # values). A second pass converges.
  if ! ./sync_addrs.sh >/dev/null 2>&1; then
    echo "FAIL: building the panic variant (sync_addrs) failed"
    exit 1
  fi
fi

isodir=isoroot-panic
rm -rf "$isodir" panic.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o panic.iso "$isodir" >grub-mkrescue-panic.log 2>&1
if [ ! -f panic.iso ]; then
  echo "FAIL: grub-mkrescue didn't produce panic.iso"
  cat grub-mkrescue-panic.log
  exit 1
fi

rm -f panic-serial.log
timeout 5 qemu-system-x86_64 -cdrom panic.iso \
  -serial file:panic-serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk

# The divide-by-zero must land in panic_handler as vector 0 (with an error
# code and CR2 field, both from the uniform trampoline frame). Matching the
# whole diagnostic line -- not just "PANIC" -- proves the right vector was
# dispatched, not merely that something crashed.
if grep -qE "^KERNEL PANIC: exception vector=0 errcode=[0-9]+ cr2=[0-9]+ rip=0x[0-9a-f]+" panic-serial.log; then
  echo "PASS: fatal #DE (divide-by-zero) reached the panic handler (vector=0 diagnostic printed)"
  exit 0
else
  echo "FAIL: panic diagnostic not found in panic-serial.log"
  echo "--- panic-serial.log ---"
  cat panic-serial.log
  exit 1
fi
