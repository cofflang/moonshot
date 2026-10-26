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
# Compiles every ring-3 program the kernel carries into build/<name>.elf,
# from source, with the same coff1 and smed that build the kernel. kmain.c0
# embeds each one (`embed lira_elf "build/lira.elf";`) and jakel_init puts it
# on the filesystem at boot. build.sh runs this before it compiles the
# kernel, so the kernel can never carry an older build of a program than its
# source, and there is nothing generated to commit and nothing to forget to
# regenerate.
#
# The test programs and lira live in programs/. Gnista and utsikt are their
# own projects. A release carries copies in programs/ (utsikt as a git
# subtree in programs/utsikt/), and in the dev tree they sit beside this
# directory. Each is taken from programs/ when it is there and from beside
# the tree otherwise; GNISTA_DIR and UTSIKT_DIR override both.
set -eu
cd "$(dirname "$0")/.."

COFF1=../c0-coff/coff1
SMED=../c0-coff/smed
[ -x "$COFF1" ] || { echo "coff1 not built at $COFF1 -- run build.sh first"; exit 1; }
[ -x "$SMED" ]  || { echo "smed not built at $SMED -- run build.sh first"; exit 1; }

if [ -z "${GNISTA_DIR:-}" ]; then
  if [ -f programs/infecteria.c0 ]; then GNISTA_DIR=programs; else GNISTA_DIR=../gnista; fi
fi
if [ -z "${UTSIKT_DIR:-}" ]; then
  if [ -f programs/utsikt/utsikt.c0 ]; then UTSIKT_DIR=programs/utsikt; else UTSIKT_DIR=../utsikt; fi
fi

# The ring-3 library (programs/lib/moon.c0), found by name through -I from
# whichever directory a program is compiled in.
LIB=$(pwd)/programs/lib
mkdir -p build
OUT=$(pwd)/build

# prog <directory> <source.c0> <name>: compiles from the program's own
# directory, since programs include their neighbours by plain name.
prog() {
  (cd "$1" && "$OLDPWD/$COFF1" --elf -I "$LIB" ${4:+-I "$4"} "$2" "$OUT/$3.s") \
    || { echo "coff --elf failed on $1/$2"; exit 1; }
  "$SMED" --base 0x80000000 "$OUT/$3.s" "$OUT/$3.elf" \
    || { echo "smed failed on $1/$2"; exit 1; }
  rm -f "$OUT/$3.s"
}

# alloc_test, layout + sizeof + alloc() (SYS_ALLOC) end to end in ring 3.
# two Entity structs, distinct fields on each, exits with their sum (114).
prog programs alloc_test.c0 alloc_test
# ticks_test, ticks() (SYS_TICKS) before and after a busy loop, exits 1 if
# the second read is greater (the counter is live and monotonic in ring 3).
prog programs ticks_test.c0 ticks_test
# crash_test, takes the CPU exception its argument names, for verify_crash.
prog programs crash_test.c0 crash_test
# The mouse tests' program, a square at the pointer while the button is held.
prog programs mouse_probe.c0 mouse_probe
# A square wave at the pitch given as its argument, for the mixing test.
prog programs tone.c0 tone
# Infecteria, the scrolling game built on Gnista's engine layer.
prog "$GNISTA_DIR" infecteria.c0 infecteria
# The full-frame render cost probe, 30 whole frames through SYS_PRESENT,
# returns the ticks they took (68 measured, about 44 fps).
prog "$GNISTA_DIR" fps_probe.c0 fps_probe
# utsikt, the browser engine, HTML and a subset of CSS from jakel, block and
# inline layout, painted in its own buffer, the kernel's font via glyph().
prog "$UTSIKT_DIR" utsikt.c0 utsikt
# lira, the piano roll, with noter songs, the synth, oljud.
prog programs/lira lira.c0 lira
# hylla, the file manager.
prog programs/hylla hylla.c0 hylla
# skrift, the text editor.
prog programs/skrift skrift.c0 skrift
# pensel, the pixel editor.
prog programs/pensel pensel.c0 pensel
# insyn, a look inside the machine.
prog programs/insyn insyn.c0 insyn
# form, the 3D modeller, on gnista's djup.
prog programs/form form.c0 form "$(cd "$GNISTA_DIR" && pwd)"
# coff and smed themselves, so Moonshot can compile and link c0 on its own.
# The same sources as the coff1 and smed that build everything here,
# unchanged. Under --elf their file builtins are Moonshot's syscalls.
prog "$(dirname "$COFF1")/c0" coff.c0 coff
prog "$(dirname "$COFF1")/c0" smed.c0 smed

for p in alloc_test ticks_test crash_test mouse_probe tone infecteria fps_probe utsikt lira hylla skrift pensel insyn form coff smed; do
  printf '  build/%s.elf  %s bytes\n' "$p" "$(stat -c %s "$OUT/$p.elf")"
done
