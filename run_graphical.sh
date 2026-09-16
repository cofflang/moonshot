#!/usr/bin/env bash
#
# run_graphical.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Boots moonshot.elf in a REAL QEMU window -- for manual, interactive
# verification (watch it boot, type on the keyboard, see the pixel
# framebuffer directly) -- unlike run_qemu.sh's automated, headless
# (-display none), serial-log-only checks, which stay the source of truth
# for CI/regression testing. This script is purely for a human to look at.
#
# Needs a QEMU UI backend package installed -- `qemu-system-x86` alone
# only ships the "none" backend (confirmed via `qemu-system-x86_64
# -display help` -- if that still only lists "none" after installing one
# of these, something else is off). On Arch:
#   sudo pacman -S qemu-ui-gtk
# (or qemu-ui-sdl if you'd rather have that one -- either works with
# `-display gtk`/`-display sdl` below, change DISPLAY_BACKEND to match).
set -eu
cd "$(dirname "$0")"

DISPLAY_BACKEND=gtk

# Run QEMU's GTK window through XWayland, not native Wayland. Moonshot's
# mouse is a PS/2 device, which is a relative pointer, and GTK under native
# Wayland delivers clicks to a relative-mode guest but almost no motion, so
# the pointer sits still while the serial log happily reports button
# changes. That is what was chased through klick for a month (2026-08 to
# 2026-09) before the A/B that found it: same binary, GDK_BACKEND=x11, and
# the pointer moved. Nothing in the kernel was ever wrong. Harmless on an
# X11 session, where this is already the backend.
export GDK_BACKEND="${GDK_BACKEND:-x11}"

./build.sh

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
if [ ! -f moonshot.iso ]; then
  echo "FAIL: grub-mkrescue didn't produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

if [ ! -f disk.img ]; then
  dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
fi

echo "Starting Moonshot in a graphical window (display=$DISPLAY_BACKEND)."
echo "Serial log is also streamed to serial.log alongside it, same as run_qemu.sh."
echo "Close the window (or Ctrl+C here) to stop -- no timeout, unlike run_qemu.sh."
rm -f serial.log
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display "$DISPLAY_BACKEND" -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk
