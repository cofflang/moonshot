#!/usr/bin/env bash
#
# run_graphical_mac.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Boots moonshot.elf in a REAL QEMU window on macOS -- for manual,
# interactive verification (watch it boot, type on the keyboard, see the
# pixel framebuffer directly).
#
# This is the macOS counterpart to run_graphical.sh. It uses -display cocoa
# (native macOS rendering) instead of -display gtk. All other flags are
# identical -- the x86_64 emulation, framebuffer, keyboard, and disk I/O
# work the same way on macOS as on Linux.
#
# Prerequisites on macOS:
#   brew install qemu
#
# That single package ships qemu-system-x86_64 with the cocoa display
# backend. No other dependencies are needed at runtime -- the ISO and
# disk.img are self-contained.
#
# To build the ISO (done on Linux, checked into the repo or scp'd over):
#   ./build.sh && ./run_graphical_mac.sh
set -eu
cd "$(dirname "$0")"

if [ ! -f moonshot.iso ]; then
  echo "moonshot.iso not found -- build it first: ./build.sh"
  exit 1
fi

if [ ! -f disk.img ]; then
  dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
  echo "Created fresh disk.img (10 MB)"
fi

echo "Starting Moonshot in a macOS-native QEMU window (display=cocoa)."
echo "Close the window to stop -- no timeout, unlike run_qemu.sh."
qemu-system-x86_64 -cdrom moonshot.iso \
  -display cocoa -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk
