#!/usr/bin/env bash
#
# screenshot.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Boots moonshot.elf headlessly, waits for it to settle, and saves a real
# screenshot of whatever is on screen into screenshots/ -- a running visual
# record of the project (deliberately committed to git, not gitignored:
# the whole point is looking back at it later, not a throwaway build
# artifact). Meant to be run:
#   - by hand, any time (./screenshot.sh, or ./screenshot.sh a-label)
#   - right after landing a new graphical feature (a real screendump each
#     time, not a description of one -- same "run the actual thing"
#     discipline as every other test script here)
#
# Usage: ./screenshot.sh [label] [wait-seconds] [sendkey ...]
#   label         optional; becomes part of the filename (default: "boot")
#   wait-seconds  optional; how long to let it boot before capturing
#                 (default 3 -- long enough for the framebuffer/VGA fallback
#                 setup in kernel_post_init to finish; bump it if the boot
#                 sequence grows and needs more time before there is anything
#                 on screen worth capturing)
#   sendkey ...   optional; any further arguments are sent as QEMU monitor
#                 `sendkey` presses (in order, 300ms apart) before the
#                 screenshot -- e.g. `./screenshot.sh typing-demo 3 h e l l o`
#                 to capture interactive typing, not just the boot screen.
set -eu
cd "$(dirname "$0")"

label="${1:-boot}"
wait_seconds="${2:-3}"
shift $(( $# < 2 ? $# : 2 )) || true
keys=("$@")

mkdir -p screenshots
outfile="screenshots/$(date +%Y-%m-%d)_${label}.png"

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

sockfile="screenshot.sock"
ppmfile="screenshot.ppm"
rm -f "$sockfile" "$ppmfile" serial.log

# Budget: initial wait + 0.3s per sendkey (they are sent one at a time,
# 300ms apart -- see the Python block below) + a few seconds of slack for
# the screendump itself and monitor round-trips. Too tight a timeout here
# kills QEMU mid-key-send once there are more than a couple of keys, which
# surfaces as a confusing BrokenPipeError from Python rather than an
# obviously-a-timeout error.
budget=$((wait_seconds + (${#keys[@]} * 1) + 5))
timeout "$budget" qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor "unix:$sockfile,server,nowait" &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null || true; rm -f "$sockfile" "$ppmfile"; }
trap cleanup EXIT

sleep "$wait_seconds"

python3 - "$sockfile" "$ppmfile" "${keys[@]}" <<'PY'
import socket, sys, time
sockfile, ppmfile = sys.argv[1], sys.argv[2]
keys = sys.argv[3:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sockfile)
time.sleep(0.3)
s.recv(4096)  # discard the monitor banner
for k in keys:
    s.sendall(("sendkey %s\n" % k).encode())
    time.sleep(0.3)
    s.recv(4096)
s.sendall(("screendump %s\n" % ppmfile).encode())
time.sleep(0.5)
s.recv(4096)
s.close()
PY

sleep 0.3
if [ ! -f "$ppmfile" ]; then
  echo "FAIL: screendump didn't produce $ppmfile"
  exit 1
fi

if command -v magick >/dev/null 2>&1; then
  magick "$ppmfile" "$outfile"
elif command -v convert >/dev/null 2>&1; then
  convert "$ppmfile" "$outfile"
else
  echo "no ImageMagick (magick/convert) found -- keeping the raw PPM instead"
  outfile="screenshots/$(date +%Y-%m-%d)_${label}.ppm"
  mv "$ppmfile" "$outfile"
fi

rm -f "$ppmfile"
echo "saved $outfile"
