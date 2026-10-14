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
# of these, something else is off). On Arch
#   sudo pacman -S qemu-ui-gtk qemu-ui-sdl
# GTK is used without sound and SDL with it, see below. DISPLAY_BACKEND=gtk
# or DISPLAY_BACKEND=sdl picks one regardless.
#
# Sound goes through an emulated Sound Blaster 16, which oljud drives. To
# hear it, QEMU needs a host audio backend, and like the UI ones they are
# separate packages on Arch
#   sudo pacman -S qemu-audio-pipewire
# (qemu-audio-pa or qemu-audio-alsa work too). The first one QEMU knows is
# used. With none installed, the sound is written to run_graphical.wav
# instead, which any player can play after the window is closed. AUDIO=none
# turns sound off, AUDIO=wav forces the recording.
#
# With a Sound Blaster attached, QEMU's GTK window stops passing keys and
# pointer motion to the guest (seen with QEMU 11.1 under GNOME on
# Xwayland, with every audio backend, wav included). The same run headless
# takes input fine, so the kernel is not the cause. The SDL window does
# not have the problem, so sound runs in SDL, and without qemu-ui-sdl
# sound is turned off rather than leaving a window that ignores input.
set -eu
cd "$(dirname "$0")"

DISPLAY_BACKEND="${DISPLAY_BACKEND:-}"

# Run QEMU's GTK window through XWayland, not native Wayland. Moonshot's
# mouse is a PS/2 device, which is a relative pointer, and GTK under native
# Wayland delivers clicks to a relative-mode guest but almost no motion, so
# the pointer sits still while the serial log happily reports button
# changes, which looks exactly like a klick bug. With the same binary and
# GDK_BACKEND=x11, the pointer moves, so nothing in the kernel is wrong. Harmless on an
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

audio="${AUDIO:-}"
if [ -z "$audio" ]; then
  available=$(qemu-system-x86_64 -audio help 2>/dev/null)
  for a in pipewire pa alsa sdl wav; do
    if printf '%s\n' "$available" | grep -qx "$a"; then audio=$a; break; fi
  done
fi
case "$audio" in
  ""|none) audio_args=() ; echo "Sound is off." ;;
  wav) audio_args=(-audiodev wav,id=snd0,path=run_graphical.wav -device sb16,audiodev=snd0)
       echo "Sound is recorded to run_graphical.wav (no QEMU audio backend found, see the top of this script)." ;;
  *) audio_args=(-audiodev "$audio",id=snd0 -device sb16,audiodev=snd0)
     echo "Sound plays through QEMU's $audio backend." ;;
esac

if [ -z "$DISPLAY_BACKEND" ]; then
  DISPLAY_BACKEND=gtk
  if [ ${#audio_args[@]} -gt 0 ]; then
    if qemu-system-x86_64 -display help 2>/dev/null | grep -qx sdl; then
      DISPLAY_BACKEND=sdl
    else
      audio_args=()
      echo "Sound is off after all, the GTK window ignores input with it (install qemu-ui-sdl, see the top of this script)."
    fi
  fi
fi

echo "Starting Moonshot in a graphical window (display=$DISPLAY_BACKEND)."
echo "Serial log is also streamed to serial.log alongside it, same as run_qemu.sh."
echo "Close the window (or Ctrl+C here) to stop -- no timeout, unlike run_qemu.sh."
rm -f serial.log
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display "$DISPLAY_BACKEND" -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  "${audio_args[@]}"
