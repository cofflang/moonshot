#!/usr/bin/env bash
#
# gen_elf_tests.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Compiles every program in elf_tests/ with `coff --elf` and smed and writes
# elf_tests_data.c0, which bakes the resulting ELF images into the kernel as
# byte arrays and installs them onto jakel at boot, plus elf_tests/manifest.txt
# for the runner.
#
# Why baked in rather than copied onto the disk: Moonshot has no way to receive
# a file from the host. Everything a ring-3 program needs to exist as a file has
# to be seeded by the kernel itself, the same way the Gnista programs are.
#
# The suite began because coff0.c implemented only the text backend, so
# c0-coff's differential tests proved nothing about the machine-code backend
# every ring-3 binary was once built through. That backend has since been
# removed: `coff --elf` now emits assembly for the Moonshot target and
# smed makes the ELF (--base 0x80000000), so ring-3 code goes through the
# same backend the differential suite checks. These programs each compute a
# value that only comes out right if codegen is correct, and return it as
# an exit code the kernel prints to serial; they stay as the end-to-end
# check that the target's syscall sequences and the loader agree.
#
# This used to be gen_elf_tests.py. The listing, the `// expect: N` lookup
# and the compiler runs are shell now, and the byte arrays are written by
# bake (bake.c0), compiled here from source by the same coff1 and smed that
# build the kernel -- so there is no python3, and nothing between the sources
# and the kernel image that is not c0 or a shell script the manifest hashes.
#
# Run via verify_elf_backend.sh, which regenerates, rebuilds and runs them.
set -eu
cd "$(dirname "$0")"
export LC_ALL=C   # the glob order below is the etNN numbering

COFF1=../c0-coff/coff1
SMED=../c0-coff/smed
[ -x "$COFF1" ] || { echo "coff1 not built at $COFF1 -- run build.sh first"; exit 1; }
[ -x "$SMED" ]  || { echo "smed not built at $SMED -- run build.sh first"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$COFF1" bake.c0 "$tmp/bake.s" && "$SMED" "$tmp/bake.s" "$tmp/bake" && chmod +x "$tmp/bake"

args=()
i=0
for src in elf_tests/*.c0; do
  i=$((i + 1))
  name=$(printf 'et%02d' "$i")
  expect=$(grep -m1 -E '^//[[:space:]]*expect:[[:space:]]*-?[0-9]+[[:space:]]*$' "$src" \
           | sed -E 's/.*expect:[[:space:]]*(-?[0-9]+).*/\1/')
  [ -n "$expect" ] || { echo "$src has no \`// expect: N\` line"; exit 1; }
  "$COFF1" --elf "$src" "$tmp/$name.s" || { echo "coff --elf failed on $src"; exit 1; }
  "$SMED" --base 0x80000000 "$tmp/$name.s" "$tmp/$name.elf" || { echo "smed failed on $src"; exit 1; }
  args+=("$name" "$(basename "$src")" "$expect" "$tmp/$name.elf")
done
[ "$i" -gt 0 ] || { echo "elf_tests/ has no .c0 programs"; exit 1; }

"$tmp/bake" tests elf_tests_data.c0 elf_tests/manifest.txt "${args[@]}"
while read -r name src expect; do
  printf '  %s.elf  %-24s expect %s\n' "$name" "$src" "$expect"
done < elf_tests/manifest.txt
