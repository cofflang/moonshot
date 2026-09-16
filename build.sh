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

COFF_DIR=../c0-coff
MANIFEST=$COFF_DIR/BOOTSTRAP.sha256
# Moonshot's own record of the coff1 it last verified. The released coff
# commits no binaries and so records none in its manifest (a manifest that
# changed whenever you built would fail on every fresh clone); only the
# private dev tree, which commits coff1, carries a coff1 line there. So the
# hash the kernel build gates on is recorded HERE, by this script, at the
# one moment it is known to be true: right after the full audit passed.
# Gitignored -- it describes a binary on this machine, not source.
COFF1_RECORD=coff1.sha256

audit_or_die() {
  (cd "$COFF_DIR" && ./verify_bootstrap.sh "$@") || {
    echo "build.sh: bootstrap verification FAILED -- refusing to build a kernel"
    echo "          with an unverified compiler. See c0-coff/TRUST.md."
    exit 1
  }
}

# Trusting-trust gate. This kernel is compiled by a binary, and a binary is
# exactly where Ken Thompson's 1984 attack lives: a compiler that recognises
# its own source and reinserts a backdoor into every compiler it builds,
# leaving no trace in any source file. coff1 was previously trusted on an
# mtime comparison -- `[ "$COFF_SRC" -nt "$COFF1" ]` -- which answers "was
# this file written after that one", a question a tampered binary answers
# correctly. git does not preserve mtimes, `touch` defeats it, and a binary
# diff inside a commit named "Backup" is not something anyone reads.
#
# So the gate is now: verify the bytes of the compiler against a recorded
# hash on EVERY build, and rebuild from source whenever the source moves.
# Fails closed -- no kernel is produced from an unverified compiler.
#
# The staleness half is kept because it caught a real bug: an unrelated
# coff.c0 edit (a debug print, added then reverted) left coff1 out of date,
# and running it against the exact same input that succeeded moments
# earlier via coff0 gave a bare PARSEERROR with zero indication the binary
# itself was the problem.
if [ ! -x "$COFF1" ] || [ "$COFF_SRC" -nt "$COFF1" ]; then
  COFF0=$COFF_DIR/coff0
  # CC selects the seed compiler. tcc is preferred when present: it is
  # reachable from the 357-byte hex0 seed through the stage0/M2-Planet/Mes
  # bootstrap chain, and gcc is reachable from nothing. A coff1
  # bootstrapped entirely through tcc is byte-identical to the gcc one and
  # produces byte-identical kernel assembly (verified 2026-09-05), so
  # preferring it costs nothing and removes gcc from this kernel's trusted
  # computing base. Override with CC=gcc to go back.
  if [ -z "${CC:-}" ]; then
    if command -v tcc >/dev/null 2>&1; then CC=tcc; else CC=gcc; fi
  fi
  if [ ! -x "$COFF0" ]; then
    echo "building coff0 with $CC (one-time bootstrap dependency for coff1)..."
    (cd "$COFF_DIR" && $CC -Wall -Wextra -o coff0 coff0.c)
  fi
  echo "(re)bootstrapping coff1 (self-hosted, via coff0)..."
  (cd "$COFF_DIR" && ./coff0 c0/coff.c0 coff1.s && as coff1.s -o coff1.o && ld coff1.o -o coff1)
  # A rebuild legitimately changes the compiler, so the recorded hashes are
  # re-derived here -- and re-derived by the full audit, not by a bare
  # sha256sum, so the new binary is checked against source before it is
  # blessed rather than merely recorded.
  # --write-manifest only where the manifest tracks binaries (the dev tree,
  # recognisable by its coff1 line): there a rebuilt coff1 makes the
  # committed line stale and the refresh is what keeps the audit green.
  # A released coff's manifest is a fixed committed file; rewriting it
  # would only dirty the clone.
  if [ -f "$MANIFEST" ] && grep -qE '^[0-9a-f]{64}  coff1$' "$MANIFEST"; then
    echo "re-verifying the bootstrap chain and refreshing the manifest..."
    audit_or_die --write-manifest
  else
    echo "re-verifying the bootstrap chain..."
    audit_or_die
  fi
  sha256sum "$COFF1" > "$COFF1_RECORD"
fi

# Cheap per-build integrity check: hashing one 84KB file costs nothing and
# needs no gcc, so it runs even on the every-build path where the whole
# point is that nothing but coff itself is required. Catches a coff1 that
# was altered after it was verified.
#
# Where the expected hash comes from, in order: the coff manifest's own
# coff1 line (dev tree), else this script's record from the last passing
# audit. A coff1 with neither -- typically one bootstrapped by hand from a
# public clone, following coff's README -- is not "tampered", it is
# unverified, so it gets the full audit now and is recorded on success.
# A coff1 that HAS a record and does not match it is the case the gate
# exists for, and that one fails closed with no automatic re-verification:
# a human has to look.
if [ -f "$MANIFEST" ] && grep -qE '^[0-9a-f]{64}  coff1$' "$MANIFEST"; then
  expected_src="c0-coff/BOOTSTRAP.sha256"
  expected=$(grep -E '^[0-9a-f]{64}  coff1$' "$MANIFEST" | cut -c1-64)
elif [ -f "$COFF1_RECORD" ]; then
  expected_src="$COFF1_RECORD"
  expected=$(cut -c1-64 "$COFF1_RECORD")
else
  echo "build.sh: no verified hash recorded for $COFF1 -- running the full"
  echo "          bootstrap audit before this compiler builds anything..."
  audit_or_die
  sha256sum "$COFF1" > "$COFF1_RECORD"
  expected_src="$COFF1_RECORD"
  expected=$(cut -c1-64 "$COFF1_RECORD")
fi
actual=$(sha256sum "$COFF1" | cut -c1-64)
if [ "$actual" != "$expected" ]; then
  echo "build.sh: coff1 does not match the hash in $expected_src."
  echo "          The compiler that would build this kernel is not the one"
  echo "          that was verified against source. Refusing to build."
  echo "          Investigate before doing anything else, then run"
  echo "          c0-coff/verify_bootstrap.sh. See c0-coff/TRUST.md."
  exit 1
fi

"$COFF1" kmain.c0 kmain.s
# kmain.c0's `include`s pull knekt.c0/interrupts.c0/jenna.c0/chrone.c0/
# vga.c0/punkt.c0/keyboard.c0 in before compilation even starts (see
# kmain.c0's own comment) -- coff1 sees and compiles ONE flat file
# regardless, so this .global step does not care which of those files a
# given function is actually written in, only its name in the assembled
# output. coff never emits `.global` for user functions (fine when
# everything is one translation unit, which is all it is ever been used
# for) -- any c0 function boot.s calls into from a separate object file
# needs to be visible, so it is added here rather than as a coff language/
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
