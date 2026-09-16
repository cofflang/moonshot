#!/usr/bin/env bash
#
# gen_programs.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Rebuilds every ring-3 program the kernel bakes in as a byte array, from
# source, with the same coff1 that builds the kernel. Each *_data.c0 this
# writes is the only form the program exists in inside the kernel, which is
# exactly why the sources have to be here and this script has to be one
# command: a byte array nobody can regenerate is a binary blob with a c0
# extension. After running it, `git diff` on the *_data.c0 files should be
# empty; if it is not, either a program's source changed (fine, rebuild the
# kernel and run ./sync_addrs.sh) or the compiler's output did (look).
#
# The test programs live in programs/. Gnista's programs are their own
# project; in my tree they sit at ../gnista, and a release ships copies in
# programs/ so the whole set builds from one checkout. GNISTA_DIR picks.
set -eu
cd "$(dirname "$0")"

COFF1=../c0-coff/coff1
GNISTA_DIR=${GNISTA_DIR:-programs}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# gen <source.c0> <elf-name> <seed-name> <output.c0> <description...>
gen() {
  src=$1; elf=$2; name=$3; out=$4; shift 4
  "$COFF1" --elf "$src" "$tmp/$elf"
  python3 gen_seed.py "$tmp/$elf" "$name" "$out" "$*"
}

gen programs/alloc_test.c0 alloc_test.elf alloc_test alloc_test_data.c0 \
"Verifies layout + sizeof + alloc() (SYS_ALLOC) end to end in a real
ring-3 --elf program: allocates two Entity structs, writes/reads distinct
fields on each, exits with their sum (114) as the exit code."

gen programs/ticks_test.c0 ticks_test.elf ticks_test ticks_test_data.c0 \
"Verifies ticks() (SYS_TICKS) end to end in a real ring-3 --elf program:
reads ticks() before and after a busy loop, exits 1 if the second read is
strictly greater (proves the counter is live and monotonic from ring 3)."

# gnista.c0 and infecteria.c0 `include` files next to them, and coff resolves
# an include against the working directory, so these compile from there.
(cd "$GNISTA_DIR" && "$OLDPWD/$COFF1" --elf gnista.c0 "$tmp/gnista.elf" \
                  && "$OLDPWD/$COFF1" --elf infecteria.c0 "$tmp/inf.elf" \
                  && "$OLDPWD/$COFF1" --elf fps_probe.c0 "$tmp/fps.elf")

python3 gen_seed.py "$tmp/gnista.elf" gnista_demo gnista_demo_data.c0 \
"Gnista's engine demo (gnista.c0, coff --elf compiled): an entity
pool of four animated movers and two static blocks, a general AABB-vs-AABB
overlap test between any two entities, all-pairs collision with
shallowest-axis resolution, arrow-key control of entity 0, and per-entity
single-blit compositing. Loads its sprite from hero.spr via SYS_READFILE
when one exists, falling back to a baked-in sprite. Re-reads win_info()
each frame so its entities bounce off the window it has NOW, not the one
it started in."

python3 gen_seed.py "$tmp/inf.elf" infecteria infecteria_data.c0 \
"Infecteria (infecteria.c0, coff --elf compiled): the scrolling game built
on Gnista's engine layer."

python3 gen_seed.py "$tmp/fps.elf" fps_probe fps_probe_data.c0 \
"Full-frame render cost probe: composites a whole tavla-sized frame with
paired 64-bit writes and presents it with SYS_PRESENT, 30 times. Returns
ticks as the exit code (~100Hz, so ms/frame = code * 10 / 30). Measured
68 ticks = ~44fps; the same loop with per-pixel writes and SYS_BLIT was
244. Sizes its buffer from win_max(), not win_info(), so a window resized
mid-run cannot make present() read past it. Source: fps_probe.c0."
