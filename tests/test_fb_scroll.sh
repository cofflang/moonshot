#!/usr/bin/env bash
#
# test_fb_scroll.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Proves fb_scroll for real. The boot banner is only 2 lines -- nowhere
# near fb_height/FONT_H = 96 rows -- so the scroll path does not
# run in a normal boot.
#
# The proof lives here rather than permanently in knekt.c0's
# kernel_post_init, where 93 forced newlines in every boot would wreck the
# "MOONSHOT\nOS\n" banner on every real boot and screenshot, and none of
# run_qemu.sh's assertions look at the banner's own pixels. It uses the same
# temporary-injection,
# always-restore-via-trap discipline as test_panic.sh/test_vga_scroll.sh,
# so the proof still runs and still asserts real pixel displacement, but
# the normal kernel's boot screen is never touched.
set -u
cd "$(dirname "$0")/.."
# The kernel sources this test patches and puts back, by absolute path, so
# the restore works from out/ too.
K=$(pwd)/kernel/core

cp $K/knekt.c0 $K/knekt.c0.panicbak
restore() {
  if [ -f $K/knekt.c0.panicbak ]; then
    mv -f $K/knekt.c0.panicbak $K/knekt.c0
  fi
}
trap restore EXIT

# Draw a marker glyph at the cursor (row 2, col 0, where the banner leaves
# it), then push newlines until fb_putc's own scroll check triggers
# exactly once, since from row 3 (marker + one newline), 93 more newlines lands
# exactly on row 96 (96*FONT_H >= fb_height), which scrolls and settles
# back to row 95 -- one scroll, not zero, not several. A real scroll
# shifts every pixel row up by FONT_H (8), so the marker (drawn at pixel rows
# 16-23, char-row 2) must now read back at pixel rows 8-15 (char-row 1),
# and char-row 2's OLD spot -- never touched by anything after the marker
# -- must now be background (whatever char-row 3, always blank, shifted
# into it).
python3 - <<'PY'
p = 'kernel/core/knekt.c0'
s = open(p).read()
marker = ('        serial_print("fb: corner_bg_match=");\n'
          '        serial_print_int(corner_bg_match);\n'
          '        serial_print("\\n");\n')
assert marker in s, "fb readback marker not found in knekt.c0"
inject = '        fb_test_scroll();\n'
s = s.replace(marker, marker + inject, 1)
open(p, 'w').write(s)
PY

if ! ./build.sh >/dev/null 2>&1; then
  echo "FAIL: building the fb-scroll variant failed"
  exit 1
fi

mkdir -p out && cd out
# A disk of its own, since out/ may be fresh.
[ -f disk.img ] || dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

isodir=isoroot-fbscroll
rm -rf "$isodir" fbscroll.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o fbscroll.iso "$isodir" >grub-mkrescue-fbscroll.log 2>&1
if [ ! -f fbscroll.iso ]; then
  echo "FAIL: grub-mkrescue did not produce fbscroll.iso"
  cat grub-mkrescue-fbscroll.log
  exit 1
fi

rm -f fbscroll-serial.log
timeout 5 qemu-system-x86_64 -cdrom fbscroll.iso \
  -serial file:fbscroll-serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk

# moved_count=18 means the marker's known lit-pixel count ('M', same as
# run_qemu.sh's fb_ok check) now reads back one character-row higher than
# where it was drawn -- proof content actually shifted up, not just that
# fb_scroll ran without crashing. cleared_count=0 means the marker's old
# spot came back background, not leftover/garbage pixels.
if grep -qE "^fb scroll: moved_count=18 cleared_count=0$" fbscroll-serial.log; then
  echo "PASS: fb_scroll shifted real screen content up by one character row and cleared the vacated row"
  exit 0
else
  echo "FAIL: expected fb scroll output not found in fbscroll-serial.log"
  echo "--- fbscroll-serial.log ---"
  cat fbscroll-serial.log
  exit 1
fi
