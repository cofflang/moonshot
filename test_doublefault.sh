#!/usr/bin/env bash
#
# test_doublefault.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Verifies the #8 double-fault IST stack by deliberately provoking a REAL double
# fault and checking the panic handler runs (vector=8 diagnostic) instead of the
# CPU silently triple-faulting and resetting.
#
# Why a double fault needs its own test, distinct from test_panic.sh's #DE: a
# double fault typically means the interrupted stack is unusable, so a #8
# handler that tried to run on that stack would just re-fault into a triple
# fault. The fix (a TSS with IST1 -> a dedicated stack, and #8's IDT entry
# selecting it) ships in the normal kernel (boot.s + knekt.c0); only the fault
# TRIGGER is test-only. boot.s's trigger_doublefault (corrupt rsp -> push ->
# fault-during-fault -> #8) is unreachable in a normal boot; this test
# temporarily injects a `call trigger_doublefault` into the boot path just
# before the scheduler starts, re-syncs the fixed addresses (the injected call
# shifts .text), boots that variant, then ALWAYS restores pristine boot.s via a
# trap. If the IST were absent/wrong, the same trigger would triple-fault and
# QEMU (-no-reboot) would exit with no vector=8 line -> this test FAILs.
set -u
cd "$(dirname "$0")"

cp boot.s boot.s.dfbak
restore() {
  if [ -f boot.s.dfbak ]; then
    mv -f boot.s.dfbak boot.s
    ./sync_addrs.sh >/dev/null 2>&1 || true
  fi
}
trap restore EXIT

# Inject the trigger just before `call sched_start` -- after kernel_post_init,
# so the IDT (with #8's IST entry) is live and the TSS is loaded. #DF is an
# exception, not a maskable IRQ, so it fires even though interrupts are still
# off here. The assert guards against the marker silently moving.
python3 - <<'PY'
p = 'boot.s'
s = open(p).read()
marker = '    call sched_start\n'
inject = '    call trigger_doublefault\n'
assert marker in s, "call sched_start marker not found in boot.s"
open(p, 'w').write(s.replace(marker, inject + marker, 1))
PY

if ! ./sync_addrs.sh >/dev/null 2>&1; then
  if ! ./sync_addrs.sh >/dev/null 2>&1; then
    echo "FAIL: building the double-fault variant (sync_addrs) failed"
    exit 1
  fi
fi

isodir=isoroot-df
rm -rf "$isodir" df.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o df.iso "$isodir" >grub-mkrescue-df.log 2>&1
if [ ! -f df.iso ]; then
  echo "FAIL: grub-mkrescue didn't produce df.iso"
  cat grub-mkrescue-df.log
  exit 1
fi

rm -f df-serial.log
timeout 5 qemu-system-x86_64 -cdrom df.iso \
  -serial file:df-serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk

# The double fault must land in panic_handler as vector 8. Reaching the handler
# AT ALL is the proof the IST worked: without a valid dedicated stack the CPU
# would have triple-faulted before any handler ran, and this line would be
# absent.
if grep -qE "^KERNEL PANIC: exception vector=8 errcode=[0-9]+ cr2=[0-9]+ rip=0x[0-9a-f]+" df-serial.log; then
  echo "PASS: real #DF reached the panic handler on its IST stack (vector=8 diagnostic printed, no triple fault)"
  exit 0
else
  echo "FAIL: vector=8 panic diagnostic not found -- IST stack likely not working (triple fault?)"
  echo "--- df-serial.log ---"
  cat df-serial.log
  exit 1
fi
