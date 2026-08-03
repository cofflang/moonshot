#!/usr/bin/env bash
#
# test_kakel_scroll.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Proves kakel's scroll works in v2 by injecting a call to kakel_test_scroll
# (defined in kakel.c0, dead code in normal boots) into kernel_post_init.
# The injected call writes a marker, floods newlines to trigger one scroll,
# and reads back the pixel proof.
set -u
cd "$(dirname "$0")"

cp knekt.c0 knekt.c0.kakelbak
trap 'if [ -f knekt.c0.kakelbak ]; then mv -f knekt.c0.kakelbak knekt.c0; fi' EXIT

python3 - <<'PY'
p = 'knekt.c0'
s = open(p).read()
marker = ('        serial_print(" stats_bg=");\n'
          '        serial_print_int(stats_bg);\n'
          '        serial_print("\\n");\n')
assert marker in s, "kakel readback marker not found in knekt.c0"
inject = '        kakel_test_scroll();\n'
s = s.replace(marker, marker + inject, 1)
open(p, 'w').write(s)
PY

if ! ./sync_addrs.sh >/dev/null 2>&1; then
  if ! ./sync_addrs.sh >/dev/null 2>&1; then
    echo "FAIL: building the kakel-scroll variant (sync_addrs) failed"
    exit 1
  fi
fi

isodir=isoroot-kakelscroll
rm -rf "$isodir" kakelscroll.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o kakelscroll.iso "$isodir" >grub-mkrescue-kakelscroll.log 2>&1
if [ ! -f kakelscroll.iso ]; then
  echo "FAIL: grub-mkrescue didn't produce kakelscroll.iso"
  cat grub-mkrescue-kakelscroll.log
  exit 1
fi

rm -f kakelscroll-serial.log
timeout 5 qemu-system-x86_64 -cdrom kakelscroll.iso \
  -serial file:kakelscroll-serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk

if grep -qE "^kakel scroll: moved=18 cleared=0$" kakelscroll-serial.log; then
  echo "PASS: window 0 scrolled its content up one cell row (marker moved, old spot cleared) -- kakel scroll works in v2"
else
  echo "FAIL: expected kakel scroll output not found in kakelscroll-serial.log"
  echo "--- kakelscroll-serial.log ---"
  grep "kakel" kakelscroll-serial.log || cat kakelscroll-serial.log
  exit 1
fi
