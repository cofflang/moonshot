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
# Compiles every program in elf_tests/ with `coff --elf` and smed, and packs
# the ELFs into build/elf_tests.pack, which the kernel embeds and unpacks onto
# jakel at boot as test/etNN.elf. Also writes elf_tests/manifest.txt for the
# runner. build.sh runs this before it compiles the kernel.
#
# Why inside the kernel rather than copied onto the disk? Moonshot has no way
# to receive a file from the host. Everything a ring-3 program needs to exist
# as a file has to be put there by the kernel itself.
#
# These programs each compute a value that only comes out right if codegen
# is correct, and return it as an exit code the kernel prints to serial.
# the end-to-end check that coff's Moonshot target, smed's image and the
# kernel's loader agree. verify_elf_backend.sh runs them.
#
# The packing is done by bake (bake.c0), compiled here from source by the
# same coff1 and smed that build the kernel, so nothing between the sources
# and the kernel image is not c0 or a shell script the manifest hashes.
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
  "$COFF1" --elf -I programs/lib "$src" "$tmp/$name.s" || { echo "coff --elf failed on $src"; exit 1; }
  "$SMED" --base 0x80000000 "$tmp/$name.s" "$tmp/$name.elf" || { echo "smed failed on $src"; exit 1; }
  args+=("$name" "$(basename "$src")" "$expect" "$tmp/$name.elf")
done
[ "$i" -gt 0 ] || { echo "elf_tests/ has no .c0 programs"; exit 1; }

mkdir -p build
"$tmp/bake" pack build/elf_tests.pack elf_tests/manifest.txt "${args[@]}" >/dev/null
while read -r name src expect; do
  printf '  %s.elf  %-24s expect %s\n' "$name" "$src" "$expect"
done < elf_tests/manifest.txt
