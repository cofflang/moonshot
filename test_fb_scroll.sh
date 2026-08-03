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
# near fb_height/FONT_H = 96 rows -- so the scroll path has never actually
# run in the normal kernel.
#
# An earlier version of this proof lived PERMANENTLY in knekt.c0's
# kernel_post_init, floating 93 forced newlines into every single boot.
# That was a mistake: it visibly wrecked the "MOONSHOT\nOS\n" banner on
# every real boot and screenshot from then on (leaving only "OS"/a stray
# marker glyph on screen, not "MOONSHOT") -- a real regression, caught by
# the user actually looking at the running kernel, not by any automated
# check (none of run_qemu.sh's assertions look at the banner's own
# pixels). Fixed by moving it here: same temporary-injection,
# always-restore-via-trap discipline as test_panic.sh/test_vga_scroll.sh,
# so the proof still runs and still asserts real pixel displacement, but
# the normal kernel's boot screen is never touched.
set -u
cd "$(dirname "$0")"

cp knekt.c0 knekt.c0.panicbak
restore() {
  if [ -f knekt.c0.panicbak ]; then
    mv -f knekt.c0.panicbak knekt.c0
    ./sync_addrs.sh >/dev/null 2>&1 || true
  fi
}
trap restore EXIT

# Draw a marker glyph at the cursor (row 2, col 0, where the banner leaves
# it), then push newlines until fb_putc's own scroll check triggers
# exactly once: from row 3 (marker + one newline), 93 more newlines lands
# exactly on row 96 (96*FONT_H >= fb_height), which scrolls and settles
# back to row 95 -- one scroll, not zero, not several. A real scroll
# shifts every pixel row up by FONT_H (8): the marker (drawn at pixel rows
# 16-23, char-row 2) must now read back at pixel rows 8-15 (char-row 1),
# and char-row 2's OLD spot -- never touched by anything after the marker
# -- must now be background (whatever char-row 3, always blank, shifted
# into it).
python3 - <<'PY'
p = 'knekt.c0'
s = open(p).read()
marker = ('        serial_print("fb: corner_bg_match=");\n'
          '        serial_print_int(corner_bg_match);\n'
          '        serial_print("\\n");\n')
assert marker in s, "fb readback marker not found in knekt.c0"
inject = '        fb_test_scroll();\n'
s = s.replace(marker, marker + inject, 1)
open(p, 'w').write(s)
PY

if ! ./sync_addrs.sh >/dev/null 2>&1; then
  if ! ./sync_addrs.sh >/dev/null 2>&1; then
    echo "FAIL: building the fb-scroll variant (sync_addrs) failed"
    exit 1
  fi
fi

isodir=isoroot-fbscroll
rm -rf "$isodir" fbscroll.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o fbscroll.iso "$isodir" >grub-mkrescue-fbscroll.log 2>&1
if [ ! -f fbscroll.iso ]; then
  echo "FAIL: grub-mkrescue didn't produce fbscroll.iso"
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
