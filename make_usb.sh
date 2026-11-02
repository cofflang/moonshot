#!/usr/bin/env bash
#
# make_usb.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Builds Moonshot and writes a bootable USB stick for real hardware (made
# for a UEFI laptop such as the Lenovo IdeaPad 1i, also boots on BIOS).
#
#   ./make_usb.sh              build, make the ISO, pick the stick, write it
#   ./make_usb.sh --no-build   reuse build/moonshot.elf as it is
#   ./make_usb.sh /dev/sdX     write to this device (still asks to confirm)
#
# Why not kernel/core/grub.cfg as it is. A UEFI machine has no VGA text
# mode, so the kernel must use the framebuffer it asks for in boot.s
# (MB_FLAGS bit 2). GRUB's EFI build only hands one over when its video
# drivers are loaded, hence `insmod all_video` and `gfxpayload=keep` in
# the config this script writes into the ISO. `gfxpayload=text` gives
# "WARNING: no console will be available to OS" and a blank screen.
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "make_usb.sh: $*" >&2; exit 1; }

BUILD=1
DEV=""
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    /dev/*) DEV="$arg" ;;
    -h|--help) sed -n 12,17p "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

# --- 1. Host packages -------------------------------------------------------
# grub gives grub-mkrescue and the i386-pc and x86_64-efi images it puts in the
# ISO, xorriso (libisoburn) writes the ISO, and mtools builds its EFI partition.
need_pkgs=()
command -v grub-mkrescue >/dev/null && [ -d /usr/lib/grub/x86_64-efi ] || need_pkgs+=(grub)
command -v xorriso >/dev/null || need_pkgs+=(libisoburn)
command -v mformat >/dev/null || need_pkgs+=(mtools)
if [ ${#need_pkgs[@]} -gt 0 ]; then
  command -v pacman >/dev/null || die "missing ${need_pkgs[*]}; install them with your package manager"
  echo "==> Installing missing packages: ${need_pkgs[*]}"
  sudo pacman -S --needed "${need_pkgs[@]}"
fi

# --- 2. Kernel --------------------------------------------------------------
grep -Eq '^\.set MB_FLAGS, 0x4' kernel/core/boot.s ||
  die "kernel/core/boot.s does not request a framebuffer (MB_FLAGS 0x4); a text-mode kernel shows nothing on UEFI"

if [ "$BUILD" = 1 ]; then
  echo "==> Building the kernel (build.sh)"
  ./build.sh
fi
[ -f build/moonshot.elf ] || die "build/moonshot.elf not found; run without --no-build"

# --- 3. ISO -----------------------------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/iso/boot/grub"
cp build/moonshot.elf "$work/iso/boot/"
cat >"$work/iso/boot/grub/grub.cfg" <<'EOF'
set timeout=3
set default=0
insmod all_video
insmod gfxterm
set gfxmode=1024x768x32,1024x768,auto
set gfxpayload=keep

menuentry "Moonshot" {
    multiboot /boot/moonshot.elf
    boot
}
EOF

iso="$work/moonshot-usb.iso"
echo "==> Making the ISO"
grub-mkrescue -o "$iso" "$work/iso" >"$work/mkrescue.log" 2>&1 ||
  { cat "$work/mkrescue.log"; die "grub-mkrescue failed"; }
xorriso -indev "$iso" -report_el_torito plain 2>/dev/null | grep -qi 'efi' ||
  die "the ISO has no EFI boot entry; check that /usr/lib/grub/x86_64-efi exists"
echo "    $(du -h "$iso" | cut -f1), boots on UEFI and BIOS"

# --- 4. Pick the USB stick --------------------------------------------------
usb_disks() { lsblk -dnpo NAME,TRAN,TYPE | awk '$2=="usb" && $3=="disk" {print $1}'; }

if [ -z "$DEV" ]; then
  echo "==> Looking for USB sticks"
  mapfile -t disks < <(usb_disks)
  [ ${#disks[@]} -gt 0 ] || die "no USB disk found; plug the stick in and run again"
  lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "${disks[@]}"
  if [ ${#disks[@]} -eq 1 ]; then
    DEV=${disks[0]}
  else
    read -rp "Which device (e.g. ${disks[0]})? " DEV </dev/tty
  fi
fi

[ -b "$DEV" ] || die "$DEV is not a block device"
[ "$(lsblk -dno TYPE "$DEV")" = disk ] || die "$DEV is a partition; give the whole disk (e.g. /dev/sdb, not /dev/sdb1)"
[ "$(lsblk -dno TRAN "$DEV")" = usb ] || die "$DEV is not a USB disk; refusing to write to it"
# Never the disk the running system lives on.
for mp in / /boot /home; do
  src=$(findmnt -no SOURCE "$mp" 2>/dev/null || true)
  [ -n "$src" ] && [ "$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)" = "$(basename "$DEV")" ] &&
    die "$DEV holds $mp; refusing"
done

size=$(lsblk -dno SIZE "$DEV")
model=$(lsblk -dno MODEL "$DEV" | sed 's/ *$//')
echo
echo "    EVERYTHING on $DEV ($size, ${model:-unknown model}) will be erased."
# Read from the terminal, after throwing away anything already typed or
# pasted (a stray Enter from pasting the command line would otherwise answer
# this prompt with an empty line). An empty answer asks again.
answer=""
while read -r -t 0.2 _ </dev/tty; do :; done
while [ -z "$answer" ]; do
  read -rp "    Type the device name ($DEV) to continue: " answer </dev/tty
done
[ "$answer" = "$DEV" ] || die "you typed '$answer', not $DEV; nothing written"

# --- 5. Write ---------------------------------------------------------------
echo "==> Writing to $DEV"
for part in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
  sudo umount "$part" 2>/dev/null || true
done
sudo wipefs -aq "$DEV"
sudo dd if="$iso" of="$DEV" bs=4M conv=fsync oflag=direct status=progress
sync

echo "==> Verifying"
bytes=$(stat -c %s "$iso")
if sudo cmp -n "$bytes" "$iso" "$DEV"; then
  echo "    The stick matches the ISO."
else
  die "readback differs from the ISO; try another stick or port"
fi
sudo eject "$DEV" 2>/dev/null || true

cat <<'EOF'

Done. You can pull the stick out.

On the IdeaPad:
  1. Turn Secure Boot OFF once. Power on and press F2 (or Fn+F2, or the
     Novo pinhole button -> BIOS Setup), Security -> Secure Boot -> Disabled,
     F10 to save. Moonshot's GRUB is not signed, so Secure Boot blocks it.
  2. Plug the stick in, power on and press F12 (or Fn+F12) for the boot
     menu, then pick the USB stick (the EFI entry).
  3. GRUB shows "Moonshot" for 3 seconds and boots it.
EOF
