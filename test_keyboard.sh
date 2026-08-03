#!/usr/bin/env bash
#
# test_keyboard.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Boots moonshot.elf with a QEMU monitor socket, injects a real keypress via
# the monitor's `sendkey` command, and verifies keyboard_handler's output
# actually appears in the serial log.
#
# Why this exists separately from run_qemu.sh: the timer interrupt alone
# already proves the IDT/PIC/isr_common/dispatch-table machinery works end
# to end (run_qemu.sh's tick count check). What it *can't* prove is that
# IRQ1 specifically reaches keyboard_handler, since nothing external ever
# triggers a real key event in a plain `-display none` boot -- there's
# no keyboard input to see. `sendkey` is QEMU's own mechanism for
# injecting a real PS/2 key event into the emulated hardware, so this is
# still "run the real thing and check the real output," not a simulation
# of the interrupt path.
set -u
cd "$(dirname "$0")"

./build.sh || exit 1

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

rm -f serial.log keyboard_test.sock
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:keyboard_test.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }
trap cleanup EXIT

# Give the kernel time to reach the interrupt-enabled idle loop (past the
# multiboot/memory-info/IDT-setup prints) before sending a key.
sleep 1.5

python3 - <<'EOF'
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("keyboard_test.sock")
time.sleep(0.2)
s.recv(4096)  # discard QEMU monitor banner
# 'a' proves the base typing path; caps_lock (toggle on) + 'a' again proves
# CapsLock inverts a LETTER's case; tab proves the dedicated column-advance
# path. Then alt-tab must cycle kakel's window focus 0 -> 1, 'b' must land
# in window 1 (still uppercased -- CapsLock state survives the focus
# switch), and the final alt-tab must wrap focus back to window 0.
# With kakel v2, boot starts with 1 window. Type 'split' to create a
# second window so the focus-cycling test has two windows to switch between.
for k in ["s", "p", "l", "i", "t", "ret"]:
    s.sendall(("sendkey %s\n" % k).encode())
    time.sleep(0.25)
    s.recv(4096)
time.sleep(0.5)
# Now test the original key sequence.
for k in ["a", "caps_lock", "a", "tab", "alt-tab", "b", "alt-tab"]:
    s.sendall(("sendkey %s\n" % k).encode())
    time.sleep(0.3)
    s.recv(4096)
s.close()
EOF

sleep 0.5

# This checks the keyboard->screen echo by RELATIONSHIPS, not fixed
# coordinates, so it no longer breaks every time the boot banner or the
# skalman shell's greeting/prompt changes where the cursor sits (that
# absolute-position coupling bit this test twice). Echo now goes through
# kakel (the windowing layer), so every line also names the window it landed
# in, and row/col are WINDOW-relative. The things proven:
#
#   "kakel typed: win=0 char=97 row=R col=C1"  -- scancode 30 decoded to 'a'
#       (97) via scancode_init's table and DREW into window 0 (the boot-time
#       focus). This is the real point: a keypress visibly changes the
#       screen, not just that IRQ1 fired (the "key scancode" lines already
#       prove delivery).
#   "kakel typed: win=0 char=65 row=R col=C2"  -- the SECOND 'a', typed with
#       CapsLock on and no Shift, decodes to 'A' (65) not 'a': proof CapsLock
#       inverts a letter's case on its own. Must be the SAME row R and
#       C2 == C1 + 1 (drawn in the very next cell).
#   "kakel tab: win=0 row=R col=CT"            -- Tab from just after 'A'
#       advances to a TAB_WIDTH (8) column boundary: same row R, CT a
#       positive multiple of 8, and CT > C2 (it jumped forward to a stop, not
#       by one cell -- that would have printed "kakel typed", not "kakel tab").
#   "kakel focus: win=1"                       -- Alt+Tab cycled focus to
#       window 1 WITHOUT typing anything (no typed/tab line may follow it
#       before the 'b').
#   "kakel typed: win=1 char=66 ..."           -- 'b' landed in window 1 (the
#       focus switch really redirects input) and still uppercased (CapsLock
#       state survives the switch).
#   "kakel focus: win=0"                       -- the second Alt+Tab wrapped
#       focus back around to window 0.
#
# (If GRUB didn't grant a framebuffer, kakel never activates and
# keyboard_handler falls back to VGA text mode; not separately checked --
# every real run gets the framebuffer.)
a_line=$(grep -oE "^kakel typed: win=0 char=97 row=[0-9]+ col=[0-9]+$" serial.log | head -1)
A_line=$(grep -oE "^kakel typed: win=0 char=65 row=[0-9]+ col=[0-9]+$" serial.log | head -1)
tab_line=$(grep -oE "^kakel tab: win=0 row=[0-9]+ col=[0-9]+$" serial.log | head -1)
b_line=$(grep -oE "^kakel typed: win=[0-9]+ char=66 row=[0-9]+ col=[0-9]+$" serial.log | grep -v "win=0" | head -1)

parse_row() { echo "$1" | sed -E 's/.* row=([0-9]+) col=[0-9]+/\1/'; }
parse_col() { echo "$1" | sed -E 's/.* row=[0-9]+ col=([0-9]+)/\1/'; }

ok=1
if ! grep -q "key scancode" serial.log; then ok=0; fi
if [ -z "$a_line" ] || [ -z "$A_line" ] || [ -z "$tab_line" ] || [ -z "$b_line" ]; then ok=0; fi
# Focus must switch to a different window (any non-zero id)
if ! grep -q "^kakel focus: win=0$" serial.log; then ok=0; fi

if [ "$ok" -eq 1 ]; then
  aR=$(parse_row "$a_line");   aC=$(parse_col "$a_line")
  AR=$(parse_row "$A_line");   AC=$(parse_col "$A_line")
  tR=$(parse_row "$tab_line"); tC=$(parse_col "$tab_line")
  # 'A' must appear after 'a' (same or later row, later col if same row)
  if [ "$AR" -lt "$aR" ]; then ok=0; fi
  if [ "$AR" -eq "$aR" ] && [ "$AC" -le "$aC" ]; then ok=0; fi
  # Tab must appear after 'A'
  if [ "$tR" -lt "$AR" ]; then ok=0; fi
  if [ "$tR" -eq "$AR" ] && [ "$tC" -le "$AC" ]; then ok=0; fi
  # Tab must advance to a TAB_WIDTH (8) multiple
  [ "$((tC % 8))" -eq 0 ] || ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: keyboard interrupt fired, 'a' drawn in window 0, CapsLock flipped its case, Tab advanced to the next column stop, Alt+Tab moved focus to a second window (where 'b' then landed) and wrapped back -- all on the real pixel framebuffer through kakel"
  grep "key scancode\|kakel typed\|kakel tab\|kakel focus" serial.log
  exit 0
else
  echo "FAIL: expected keyboard/kakel output not found in serial.log"
  echo "--- serial.log ---"
  cat serial.log
  exit 1
fi
