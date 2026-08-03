#!/usr/bin/env bash
#
# test_vga_scroll.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Proves vga_scroll for real. Every real boot on this machine gets a usable
# pixel framebuffer from GRUB, so the VGA fallback path (including
# vga_scroll) has never actually been exercised -- same gap fb_scroll had
# until knekt.c0's kernel_post_init got a permanent proof for it.
#
# A first attempt at this script forced fb_available=0 at the c0 level and
# found the VGA readback came back all 255s -- a real, worth-remembering
# discovery, not a bug in the test: boot.s's Multiboot header
# unconditionally REQUESTS a linear graphics mode (flags bit 2), and GRUB
# puts the hardware in that mode regardless of what fb_available says
# afterward at the c0 level. 0xB8000 only holds real VGA text-mode content
# when the hardware is actually IN text mode -- forcing the c0-side
# variable doesn't undo GRUB's own mode-setting. Confirmed by temporarily
# zeroing MB_FLAGS (no video mode requested at all): GRUB then reports a
# type=2 (EGA text) "framebuffer", fb_probe correctly rejects it as
# unsupported and falls back to VGA on its own, and the readback came back
# exactly as documented from before punkt.c0 existed (char0=77 attr0=7
# char7=116 char_row1_0=79) -- so the fix is to stop *requesting* the
# graphics mode, not to fight fb_available after the fact.
#
# So this temporarily patches TWO files, same "always restore via a trap"
# discipline as test_panic.sh: boot.s (MB_FLAGS 0x4 -> 0x0, so GRUB leaves
# the card in real text mode) and knekt.c0 (a scroll-forcing test appended
# to the existing VGA readback block -- fb_available is already 0 in this
# variant, no need to force it).
set -u
cd "$(dirname "$0")"

cp boot.s boot.s.panicbak
cp knekt.c0 knekt.c0.panicbak
restore() {
  if [ -f boot.s.panicbak ]; then
    mv -f boot.s.panicbak boot.s
  fi
  if [ -f knekt.c0.panicbak ]; then
    mv -f knekt.c0.panicbak knekt.c0
    ./sync_addrs.sh >/dev/null 2>&1 || true
  fi
}
trap restore EXIT

python3 - <<'PY'
p = 'boot.s'
s = open(p).read()
marker = '.set MB_FLAGS, 0x4\n'
assert marker in s, "MB_FLAGS marker not found in boot.s"
open(p, 'w').write(s.replace(marker, '.set MB_FLAGS, 0x0\n', 1))
PY

# Draw a marker glyph at the cursor (row 2, col 0 -- vga_row/vga_col after
# "Moonshot\nOS\n"), then push newlines until vga_putc's own scroll check
# triggers exactly once (from row 3, 22 more newlines lands exactly on
# row 25 = VGA_HEIGHT, which scrolls and settles back to row 24). A real
# scroll moves every row up by one: the marker (row 2) must now read back
# at row 1, and row 2's OLD spot -- never touched by anything after the
# marker -- must be back to a blank space cell.
python3 - <<'PY'
p = 'knekt.c0'
s = open(p).read()
readback_marker = ('        serial_print_int(load8(VGA_BUFFER + VGA_WIDTH * 2));\n'
                    '        serial_print("\\n");\n')
assert readback_marker in s, "vga readback marker not found in knekt.c0"
inject = ('        int scroll_i = 0;\n'
          "        vga_putc('M', VGA_DEFAULT_ATTR);\n"
          "        vga_putc('\\n', VGA_DEFAULT_ATTR);\n"
          '        while (scroll_i < 22) {\n'
          "            vga_putc('\\n', VGA_DEFAULT_ATTR);\n"
          '            scroll_i = scroll_i + 1;\n'
          '        }\n'
          '        int vga_moved = load8(VGA_BUFFER + (1 * VGA_WIDTH + 0) * 2);\n'
          '        int vga_cleared = load8(VGA_BUFFER + (2 * VGA_WIDTH + 0) * 2);\n'
          '        serial_print("vga scroll: moved=");\n'
          '        serial_print_int(vga_moved);\n'
          '        serial_print(" cleared=");\n'
          '        serial_print_int(vga_cleared);\n'
          '        serial_print("\\n");\n')
s = s.replace(readback_marker, readback_marker + inject, 1)
open(p, 'w').write(s)
PY

if ! ./sync_addrs.sh >/dev/null 2>&1; then
  if ! ./sync_addrs.sh >/dev/null 2>&1; then
    echo "FAIL: building the vga-scroll variant (sync_addrs) failed"
    exit 1
  fi
fi

isodir=isoroot-vgascroll
rm -rf "$isodir" vgascroll.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o vgascroll.iso "$isodir" >grub-mkrescue-vgascroll.log 2>&1
if [ ! -f vgascroll.iso ]; then
  echo "FAIL: grub-mkrescue didn't produce vgascroll.iso"
  cat grub-mkrescue-vgascroll.log
  exit 1
fi

rm -f vgascroll-serial.log
timeout 5 qemu-system-x86_64 -cdrom vgascroll.iso \
  -serial file:vgascroll-serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk

# moved=77 ('M'): the marker read back one row higher than it was drawn --
# proof vga_scroll actually shifted content up. cleared=32 (' '): the
# marker's old spot came back blank, not leftover garbage. Also requires
# the baseline vga: readback (char0=77) to still hold, confirming this
# variant genuinely booted into real VGA text mode, not silently failing
# some other way.
if grep -qE "^vga: char0=77 " vgascroll-serial.log \
   && grep -qE "^vga scroll: moved=77 cleared=32$" vgascroll-serial.log; then
  echo "PASS: vga_scroll shifted real screen content up by one row and cleared the vacated row"
  exit 0
else
  echo "FAIL: expected vga scroll output not found in vgascroll-serial.log"
  echo "--- vgascroll-serial.log ---"
  cat vgascroll-serial.log
  exit 1
fi
