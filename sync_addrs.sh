#!/usr/bin/env bash
#
# sync_addrs.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Patches kmain.c0's JIT helper address literals to match the actual function
# addresses in the linked ELF. The section-address symbols (kscratch_start,
# idt_start, dispatch_start, _kernel_end) are now linker-resolved via `extern`
# declarations — no runtime patching needed for those.
#
# Only JIT_PRINT_ADDR, JIT_PRINT_STR_ADDR, and JIT_ASSIGN_ADDR remain as
# hand-patched integer globals, because declaring `extern int jit_print_helper`
# would collide with the same-name function definition in the same translation
# unit.
#
# Why a single build+patch pass converges: coff1 emits these address literals
# as fixed-width immediates, so changing a literal's *value* never changes any
# instruction's *length*, so re-linking after the patch cannot shift the very
# addresses just written.
set -eu
cd "$(dirname "$0")"

read_sym_addr()  { nm moonshot.elf | awk -v s="$1" '$3==s{print $1; exit}'; }

patch_literal() { # name  decimal-value
  sed -i "s/^int $1 *= .*/int $1 = $2;/" kmain.c0
}

./build.sh >/dev/null

changed=0

patch_one() {
  local var="$1" sym="$2"
  local hex dec cur
  hex=$(read_sym_addr "$sym")
  dec=$(printf '%d' "0x$hex")
  cur=$(awk -v v="$var" '{gsub(/;/,""); for(i=1;i<=NF;i++) if($i==v && $(i+1)=="=") {print $(i+2); exit}}' kmain.c0)
  if [ "$cur" != "$dec" ]; then
    echo "  $var: $cur -> $dec  (from $sym @ 0x$hex)"
    patch_literal "$var" "$dec"
    changed=1
  fi
}

patch_one JIT_PRINT_ADDR     jit_print_helper
patch_one JIT_PRINT_STR_ADDR jit_print_str_helper
patch_one JIT_ASSIGN_ADDR    jit_assign_helper

if [ "$changed" -eq 0 ]; then
  echo "sync_addrs: already in sync, nothing to patch."
  exit 0
fi

# Rebuild with the patched literals, then verify stability.
./build.sh >/dev/null
fail=0

verify_one() {
  local var="$1" sym="$2"
  local dec cur
  dec=$(printf '%d' "0x$(read_sym_addr "$sym")")
  cur=$(awk -v v="$var" '{gsub(/;/,""); for(i=1;i<=NF;i++) if($i==v && $(i+1)=="=") {print $(i+2); exit}}' kmain.c0)
  [ "$cur" = "$dec" ] || { echo "  MISMATCH after rebuild: $var literal=$cur actual=$dec"; fail=1; }
}

verify_one JIT_PRINT_ADDR     jit_print_helper
verify_one JIT_PRINT_STR_ADDR jit_print_str_helper
verify_one JIT_ASSIGN_ADDR    jit_assign_helper

if [ "$fail" -ne 0 ]; then
  echo "sync_addrs: retrying (first pass shifted)..."
  fail=0
  ./build.sh >/dev/null
  verify_one JIT_PRINT_ADDR     jit_print_helper
  verify_one JIT_PRINT_STR_ADDR jit_print_str_helper
  verify_one JIT_ASSIGN_ADDR    jit_assign_helper
  if [ "$fail" -ne 0 ]; then
    echo "sync_addrs: FAILED after two passes — investigate before trusting the build."
    exit 1
  fi
fi
echo "sync_addrs: patched and re-verified stable."
