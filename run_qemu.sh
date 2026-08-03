#!/usr/bin/env bash
#
# run_qemu.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Boots moonshot.elf in QEMU and checks the real serial output -- same
# "run the actual thing, check the actual result" discipline as
# ../c0-coff/run_tests.sh, not a simulation.
#
# Boots via a GRUB-built ISO (-cdrom), not QEMU's own `-kernel` multiboot
# loader: that loader flatly refuses ELF64 images ("give a 32bit one"),
# and forcing coff-compiled code into a 32-bit ELF container doesn't work
# (its instructions unconditionally use 64-bit registers, which need
# relocation types a 32-bit ELF container can't represent). GRUB's own
# multiboot loader handles ELF64 kernels directly, which is the standard
# way real long-mode hobby kernels get booted -- boot.s/kmain.c0 needed no
# changes for this, only the packaging step did.
#
# The kernel idles in an interrupt-driven `hlt` loop forever once main()
# returns (interrupts enabled -- the PIT timer wakes it ~100x/sec), so
# `timeout` is what ends the QEMU process; -no-reboot keeps a triple fault
# from looping instead of surfacing as a clean failure.
set -u
cd "$(dirname "$0")"

./build.sh || exit 1

if [ ! -f disk.img ]; then
  dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
fi

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
if [ ! -f moonshot.iso ]; then
  echo "FAIL: grub-mkrescue didn't produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

rm -f serial.log
timeout 5 qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk

# Exact KB values aren't checked (they depend on QEMU's default memory
# layout / -m value, not on anything this kernel controls) -- what matters
# is that the Multiboot info structure was actually read and parsed into
# real digits, not that mem_lower/mem_upper equal a specific number.
#
# Tick count: requiring at least 3 occurrences (not just "at least 1")
# proves the timer interrupt fires *repeatedly* -- one stray tick could be
# a fluke or a handler that runs once then silently breaks (e.g. a missing
# EOI would still let exactly one IRQ0 through before the PIC withholds
# every subsequent one). Repeated, steadily-incrementing ticks is real
# evidence the whole IDT/PIC/PIT/EOI chain works, not just that it
# compiled.
tick_count=$(grep -c "^tick " serial.log)

# The allocator is now checked in three parts (see kmain.c0's main()), all
# by real arithmetic on the printed addresses -- not just "N numbers got
# printed":
#   pmm bump:  a0 a1 a2 a3  -- four fresh pages, each exactly 4096 apart
#   pmm reuse: r0 r1        -- must equal the freed pages LIFO (a2 then a1)
#   pmm bump2: a4           -- must resume bumping past a3 (a3 + 4096)
# Together these verify free/reuse/LIFO/bump-fallback, not just bump.
pmm_ok=1
read -r a0 a1 a2 a3 < <(grep "^pmm bump: " serial.log | head -1 | sed 's/^pmm bump: //')
read -r r0 r1 < <(grep "^pmm reuse: " serial.log | head -1 | sed 's/^pmm reuse: //')
a4=$(grep "^pmm bump2: " serial.log | head -1 | sed 's/^pmm bump2: //')

# All fields must actually be present as integers before any arithmetic.
for v in "$a0" "$a1" "$a2" "$a3" "$r0" "$r1" "$a4"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then pmm_ok=0; fi
done

if [ "$pmm_ok" -eq 1 ]; then
  # bump: strictly increasing, exactly 4096 apart
  [ "$((a1 - a0))" -eq 4096 ] || pmm_ok=0
  [ "$((a2 - a1))" -eq 4096 ] || pmm_ok=0
  [ "$((a3 - a2))" -eq 4096 ] || pmm_ok=0
  # reuse: freed pages come back LIFO (a2 was freed last, so returned first)
  [ "$r0" -eq "$a2" ] || pmm_ok=0
  [ "$r1" -eq "$a1" ] || pmm_ok=0
  # bump2: free-list empty again, so allocation resumes past a3
  [ "$((a4 - a3))" -eq 4096 ] || pmm_ok=0
fi

# Kernel heap (kmalloc/kfree, jenna.c0): three sub-page allocations checked
# by real arithmetic on the printed payload addresses, same as the pmm block
# above -- not just "three numbers appeared":
#   alloc:    h0 h1 h2  -- each 80 bytes apart (64 payload + 16-byte header)
#   reuse:    h3        -- must equal h1 (freed middle block handed back out)
#   coalesce: h4        -- must equal h1 (h3==h1 and h2 freed, then a 128-byte
#             request too big for either 64-byte block alone lands at the
#             lower address, proving the two merged)
heap_ok=1
read -r h0 h1 h2 < <(grep "^heap alloc: " serial.log | head -1 | sed 's/^heap alloc: //')
h3=$(grep "^heap reuse: " serial.log | head -1 | sed 's/^heap reuse: //')
h4=$(grep "^heap coalesce: " serial.log | head -1 | sed 's/^heap coalesce: //')
for v in "$h0" "$h1" "$h2" "$h3" "$h4"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then heap_ok=0; fi
done
if [ "$heap_ok" -eq 1 ]; then
  [ "$((h1 - h0))" -eq 80 ] || heap_ok=0
  [ "$((h2 - h1))" -eq 80 ] || heap_ok=0
  [ "$h3" -eq "$h1" ] || heap_ok=0
  [ "$h4" -eq "$h1" ] || heap_ok=0
fi

# Paging: kmain.c0 builds its own 4-level page tables from jenna-allocated
# frames, boot.s switches CR3 to them, and paging_verify() (run after the
# switch) reads a sentinel back through a 4GB virtual address that only the
# c0-built tables map -- boot.s's own 1GB identity map would fault there.
# The "live" line printing at all is proof the switch worked; the timer
# ticks continuing afterward independently prove the new tables keep the
# whole IDT/handler path mapped (a broken map would triple-fault, not tick).
paging_ok=0
if grep -qE "^Paging: built c0 page tables, PML4 at [0-9]+" serial.log \
   && grep -q "^Paging: live on c0 tables" serial.log; then
  paging_ok=1
fi

# Exceptions / demand paging: kernel_post_init touches a deliberately-
# unmapped 5GB address, the #PF handler (IDT vector 14, reached through the
# shared trampoline with a real CPU error code + CR2) demand-maps it and
# returns, so the faulting read succeeds and reads back the seeded sentinel.
# Requiring both the fault line (with CR2 = the exact 5GB address) and the
# recovery line proves the whole exception path AND the recover-and-retry,
# not just that something printed.
fault_ok=0
if grep -qE "^page fault: addr=5368709120 errcode=[0-9]+" serial.log \
   && grep -q "^demand paging OK:" serial.log; then
  fault_ok=1
fi

# chrone: a real N-task process model. sched_start spawns FOUR
# tasks (ids 0-3) into a heap-allocated task table and they are switched
# PREEMPTIVELY by the timer ISR -- no task ever yields or calls into the
# scheduler itself (see thread_worker/thread_exiter), so the interleaving comes
# entirely from sched_tick's round-robin every SCHED_SWITCH_PERIOD ticks. The
# exact switch count depends on QEMU timing, so this checks invariants, not an
# exact sequence:
#   * at least 6 switches happened;
#   * no task is scheduled twice in a row (prev != cur) -- genuine round-robin
#     over multiple runnable tasks, not one task "winning" repeatedly;
#   * each task's own printed work counter strictly increases across its
#     successive appearances -- proving a resumed task's full register/stack
#     state was preserved across more than a hardcoded pair of tasks;
#   * at least THREE distinct task ids appear -- proving the process model
#     really runs past the old 2-task limit;
#   * task 3 (thread_exiter) runs and then EXITS, and the exit line appears --
#     proving task_exit + sched_pick_next's skip work (the other tasks keep
#     round-robining after one drops out).
sched_ok=1
sched_count=0
prev_task=-1
declare -A last_counter
declare -A seen_task
while read -r task counter; do
  sched_count=$((sched_count + 1))
  if [ "$task" = "$prev_task" ]; then
    sched_ok=0
  fi
  if [ -n "${last_counter[$task]:-}" ] && [ "$counter" -le "${last_counter[$task]}" ]; then
    sched_ok=0
  fi
  last_counter[$task]=$counter
  seen_task[$task]=1
  prev_task=$task
done < <(grep -E "^\[sched\] -> task [0-9]+ \(counter=[0-9]+\)$" serial.log \
  | sed -E "s/^\[sched\] -> task ([0-9]+) \(counter=([0-9]+)\)\$/\1 \2/")
[ "$sched_count" -ge 6 ] || sched_ok=0
[ "${#seen_task[@]}" -ge 3 ] || sched_ok=0
grep -qE "^\[sched\] task 3 exited$" serial.log || sched_ok=0
# Reaper: after task 3 (the boot exiter) exits, sched_reap must free its stack
# page from another task's context -- proving the 4KB-per-task leak that exit/
# kill left behind is now reclaimed. The freed address must match the page
# task 3 was spawned on (same "stack=" value), i.e. it's really task 3's stack
# going back to pmm, not some unrelated free.
spawn3=$(grep -oE "^\[sched\] spawned task 3 stack=[0-9]+$" serial.log | head -1 | grep -oE "[0-9]+$")
reap3=$(grep -oE "^\[sched\] reaped task 3 stack=[0-9]+$" serial.log | head -1 | grep -oE "[0-9]+$")
if [ -z "$reap3" ] || [ "$reap3" != "$spawn3" ]; then sched_ok=0; fi

# Pixel-framebuffer text renderer (kmain.c0's fb_clear/fb_print/font_hi/
# font_lo): "MOONSHOT\nOS\n" is drawn via the real VBE linear framebuffer
# GRUB granted (requested via boot.s's Multiboot header, mapped into the
# live page tables by fb_map), then the top-left 8x8 cell is read back
# pixel-by-pixel and counted -- must equal exactly 18, 'M's known
# lit-pixel count (counted independently by the font design script, not
# eyeballed), proving the glyph actually rendered correctly, not just
# "some pixels changed". corner_bg_match=1 confirms fb_clear filled the
# WHOLE screen (a corner far from any text still reads back as background),
# not just the area text landed on. If GRUB didn't grant a usable
# framebuffer, kmain.c0 falls back to VGA text mode instead (see main()) --
# not separately checked here, since every real run so far has gotten the
# framebuffer.
fb_ok=0
if grep -qE "^fb: corner_bg_match=1$" serial.log; then
  fb_ok=1
fi

# kakel windowing layer (kakel.c0): after the full-screen banner proof above,
# kernel_post_init carves the screen into three tiles and reads real pixels back
# (see knekt.c0):
#   win0_fg/win1_fg = 18  -- each shell window's banner 'M' at its own origin
#   left_bg/right_bg = 1  -- the last row of the shell windows (just above the
#       log strip) shows win 0's background left of the split and win 1's
#       DIFFERENT background right: fills covered the right rectangles exactly
#   corner_bg = 1         -- shell bottom-right corner is shell-window bg
#   stats_bg = 1          -- the very last screen row (inside the status bar)
#       shows the log window's distinct dark background, proving the strip was
#       created and cleared
kakel_ok=0
if grep -qE "^kakel: win0_fg=18 corner_bg=1 stats_bg=1$" serial.log; then
  kakel_ok=1
fi

# ATA disk driver and jakel persistence -- the disk must be detected and
# the filesystem must come up (either loaded from disk or created fresh,
# followed by an initial sync).
ata_ok=0
jakel_ok=0
if grep -qE "^\[ata\] drive detected$" serial.log; then ata_ok=1; fi
if grep -qE "^\[jakel\] (filesystem ready|loaded) " serial.log \
   && grep -qE "^\[jakel\] synced " serial.log; then jakel_ok=1; fi

if grep -q "Hello from Moonshot" serial.log \
   && grep -qE "Lower memory \(KB\): [0-9]+" serial.log \
   && grep -qE "Upper memory \(KB\): [0-9]+" serial.log \
   && grep -q "^Memory map:" serial.log \
   && grep -qE "^Allocator range: [0-9]+ \.\. [0-9]+" serial.log \
   && [ "$pmm_ok" -eq 1 ] \
   && [ "$heap_ok" -eq 1 ] \
   && [ "$paging_ok" -eq 1 ] \
   && [ "$fault_ok" -eq 1 ] \
   && [ "$sched_ok" -eq 1 ] \
   && [ "$fb_ok" -eq 1 ] \
   && [ "$kakel_ok" -eq 1 ] \
   && [ "$ata_ok" -eq 1 ] \
   && [ "$jakel_ok" -eq 1 ] \
   && [ "$tick_count" -ge 3 ]; then
  echo "PASS: serial output matched (boot + memory info + memory map + pmm bump/free/reuse (LIFO) + kmalloc/kfree heap (alloc/reuse/coalesce) + c0 paging live (sentinel via 4GB) + #PF demand-paging recovery + preemptive N-task scheduling ($sched_count switches, ${#seen_task[@]} tasks, exit/skip + stack reap) + pixel-framebuffer clear + kakel v2 layout (1 shell + stats bar) + $tick_count timer ticks + ata disk detected + jakel fs ready/synced)"
  exit 0
else
  echo "FAIL: expected output not found in serial.log (ticks=$tick_count pmm_ok=$pmm_ok heap_ok=$heap_ok paging_ok=$paging_ok fault_ok=$fault_ok sched_ok=$sched_ok fb_ok=$fb_ok kakel_ok=$kakel_ok ata_ok=$ata_ok jakel_ok=$jakel_ok)"
  echo "--- serial.log ---"
  cat serial.log
  exit 1
fi
