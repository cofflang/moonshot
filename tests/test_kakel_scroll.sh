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
# Proves kakel's scroll works by injecting a call to kakel_test_scroll
# (defined in kakel.c0, dead code in normal boots) into kernel_post_init.
# The injected call writes a marker, floods newlines to trigger one scroll,
# and reads back the pixel proof.
set -u
cd "$(dirname "$0")/.."
# The kernel sources this test patches and puts back, by absolute path, so
# the restore works from out/ too.
K=$(pwd)/kernel/core

cp $K/knekt.c0 $K/knekt.c0.kakelbak
trap 'if [ -f $K/knekt.c0.kakelbak ]; then mv -f $K/knekt.c0.kakelbak $K/knekt.c0; fi' EXIT

python3 - <<'PY'
p = 'kernel/core/knekt.c0'
s = open(p).read()
marker = ('        serial_print(" stats_bg=");\n'
          '        serial_print_int(stats_bg);\n'
          '        serial_print("\\n");\n')
assert marker in s, "kakel readback marker not found in knekt.c0"
inject = '        kakel_test_scroll();\n'
s = s.replace(marker, marker + inject, 1)
open(p, 'w').write(s)
PY

if ! ./build.sh >/dev/null 2>&1; then
  echo "FAIL: building the kakel-scroll variant failed"
  exit 1
fi

mkdir -p out && cd out
# A disk of its own, since out/ may be fresh.
[ -f disk.img ] || dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

isodir=isoroot-kakelscroll
rm -rf "$isodir" kakelscroll.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o kakelscroll.iso "$isodir" >grub-mkrescue-kakelscroll.log 2>&1
if [ ! -f kakelscroll.iso ]; then
  echo "FAIL: grub-mkrescue did not produce kakelscroll.iso"
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
