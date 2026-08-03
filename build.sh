#!/usr/bin/env bash
#
# build.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Builds moonshot.elf: kmain.c0 compiled by coff1 -- the self-hosted c0
# compiler (built from c0/coff.c0) -- not coff0.c, the C-based reference
# implementation. boot.s assembled as hand-written 32/64-bit mixed asm,
# linked with linker.ld at 1MiB.
#
# Why coff1, not coff0: coff0.c is legacy bootstrap scaffolding from before
# coff achieved self-hosting -- it stays only as the differential-testing
# oracle inside c0-coff's own test suite (verifying coff.c0/coff1's output
# stays correct), not as the thing that actually compiles Moonshot.
# Building the kernel through coff0 would mean depending on gcc and the
# whole C toolchain at build time, even though the *output* kernel binary
# is freestanding -- exactly the dependency this project wants minimized.
# coff1 needs gcc/coff0 only once, to bootstrap itself (below); every build
# after that needs nothing but the c0 compiler.
#
# `coff0 kmain.c0 out.s` and `coff1 kmain.c0 out.s` produce byte-identical
# assembly output, not just "compiles equally well." Getting there needed
# one real fix: coff.c0's `main()` read source through a fixed 65536-byte
# buffer, which silently truncated kmain.c0 mid-file -- see c0-coff's
# c0/coff.c0 (and the same fix in lex.c0/parse.c0) for the full story.
set -eu
cd "$(dirname "$0")"

COFF1=../c0-coff/coff1
COFF_SRC=../c0-coff/c0/coff.c0

# Staleness check, not just existence: a coff1 binary older than the
# coff.c0 source that produced it is stale and silently wrong -- found the
# hard way while splitting kmain.c0 into subsystem files: an unrelated
# coff.c0 edit (a debug print, added then reverted) left coff1 out of
# date, and running it against the exact same input that succeeded
# moments earlier via coff0 gave a bare PARSEERROR with zero indication
# the binary itself was the problem. `-nt` (newer than) catches this the
# same way `make` would.
if [ ! -x "$COFF1" ] || [ "$COFF_SRC" -nt "$COFF1" ]; then
  COFF0=../c0-coff/coff0
  if [ ! -x "$COFF0" ]; then
    echo "building coff0 (one-time bootstrap dependency for coff1)..."
    (cd ../c0-coff && gcc -Wall -Wextra -o coff0 coff0.c)
  fi
  echo "(re)bootstrapping coff1 (self-hosted, via coff0)..."
  (cd ../c0-coff && ./coff0 c0/coff.c0 coff1.s && as coff1.s -o coff1.o && ld coff1.o -o coff1)
fi

"$COFF1" kmain.c0 kmain.s
# kmain.c0's `include`s pull knekt.c0/interrupts.c0/jenna.c0/chrone.c0/
# vga.c0/punkt.c0/keyboard.c0 in before compilation even starts (see
# kmain.c0's own comment) -- coff1 sees and compiles ONE flat file
# regardless, so this .global step doesn't care which of those files a
# given function is actually written in, only its name in the assembled
# output. coff never emits `.global` for user functions (fine when
# everything is one translation unit, which is all it's ever been used
# for) -- any c0 function boot.s calls into from a separate object file
# needs to be visible, so it's added here rather than as a coff language/
# codegen change. main (knekt.c0): called from boot.s's long_mode_start.
# int_dispatch (interrupts.c0): called from boot.s's isr_common trampoline
# (see boot.s for why the trampoline itself has to be hand-written asm,
# not c0). paging_verify (jenna.c0): called from boot.s right after it
# loads CR3 with the c0-built page tables. kernel_post_init (knekt.c0):
# called from boot.s after lidt (needs a live IDT for the demand-paging
# fault test) -- also test_panic.sh's injection target, see that script.
# timer_tick/keyboard_handler/page_fault_handler do NOT need this: boot.s
# never calls them by name -- kmain.c0's expanded content only references
# them internally (dispatch_set(32, timer_tick), etc.), a same-object-file
# reference that needs no `.global` at all. sched_start (chrone.c0): called
# from boot.s as scheduler task A (thread_b/sched_launch_call stay internal
# -- thread_b is only referenced by address via c0's function-reference
# feature, and sched_launch itself is called indirectly through the
# .sched slot).
sed -i '1i .global main\n.global int_dispatch\n.global paging_verify\n.global kernel_post_init\n.global sched_start\n.global sys_dispatch' kmain.s
as boot.s -o boot.o
as kmain.s -o kmain.o
as ring3_handlers.s -o ring3_handlers.o
ld -T linker.ld -o moonshot.elf boot.o kmain.o ring3_handlers.o

echo "built moonshot.elf"
