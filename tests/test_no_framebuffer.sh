#!/usr/bin/env bash
#
# test_no_framebuffer.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Boots a kernel that was granted no pixel framebuffer and proves the
# timer interrupt survives. With no framebuffer kakel never starts, so
# kakel_stats_win stays -1 and kakel_bg_base stays 0. The status bar code
# must then do nothing, and a read at kakel_bg_base - 8 must not happen.
#
# The absence is made the way test_vga_scroll.sh makes it. boot.s's
# MB_FLAGS is zeroed for this build only, so GRUB is not asked for a
# graphics mode, and the file is put back by a trap. The shipped header
# is not changed.
#
# Passes when the serial log has no page fault other than the deliberate
# demand-paging probe, no panic, ticks pass 300 (3 seconds), the VGA text
# screen shows the login, accepts root, shows the shell prompt and serves an
# echo command, the status bar helpers in chrone.c0 carry the guard, and an
# ordinary framebuffer boot still redraws its status bar as uptime passes.
set -u
cd "$(dirname "$0")/.."
K=$(pwd)/kernel/core

# Only sched_stats_update runs in this boot, so the meter helper is checked in
# the source instead. Every chrone.c0 function that indexes a kakel array by
# kakel_stats_win must start with the stats_bar_ready guard, and that guard
# must refuse a negative window id and null arrays.
src_rc=0
if ! python3 - <<'PY'
import re, sys
s = open('kernel/core/chrone.c0').read()
bad = []
ready = re.search(r'int stats_bar_ready\(\) \{(.*?)\n\}', s, re.S)
if not ready or 'kakel_stats_win < 0' not in ready.group(1) \
        or 'kakel_bg_base == 0' not in ready.group(1):
    bad.append('stats_bar_ready does not refuse a negative id and a null kakel_bg_base')
for m in re.finditer(r'\n(?:int|void) (\w+)\([^)]*\) \{\n(.*?)\n\}', s, re.S):
    name, body = m.group(1), m.group(2)
    if 'kakel_stats_win * 8' not in body:
        continue
    first = body.strip().split('\n')[0].strip()
    if first != 'if (stats_bar_ready() == 0) { return; }':
        bad.append(name + ' indexes by kakel_stats_win without the guard first')
for b in bad:
    print('FAIL: ' + b)
sys.exit(1 if bad else 0)
PY
then
  src_rc=1
fi

cp $K/boot.s $K/boot.s.nofbbak
restore() {
  if [ -f $K/boot.s.nofbbak ]; then
    mv -f $K/boot.s.nofbbak $K/boot.s
  fi
}
trap restore EXIT

python3 - <<'PY'
p = 'kernel/core/boot.s'
s = open(p).read()
marker = '.set MB_FLAGS, 0x4\n'
assert marker in s, "MB_FLAGS marker not found in boot.s"
open(p, 'w').write(s.replace(marker, '.set MB_FLAGS, 0x0\n', 1))
PY

if ! ./build.sh >/dev/null 2>&1; then
  echo "FAIL: building the no-framebuffer variant failed"
  exit 1
fi
restore

mkdir -p out && cd out
[ -f disk.img ] || dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

isodir=isoroot-nofb
rm -rf "$isodir" nofb.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o nofb.iso "$isodir" >grub-mkrescue-nofb.log 2>&1
if [ ! -f nofb.iso ]; then
  echo "FAIL: grub-mkrescue did not produce nofb.iso"
  cat grub-mkrescue-nofb.log
  exit 1
fi

rm -f nofb-serial.log nofb.sock
qemu-system-x86_64 -cdrom nofb.iso \
  -serial file:nofb-serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:nofb.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f nofb.sock; }
trap 'cleanup; restore' EXIT

sleep 4

# The text login and shell prompt are only on the VGA screen, so the test reads
# the text buffer through the monitor, logs in as root with an empty password
# and reads it again.
python3 - <<'PY'
import socket, time, re, sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("nofb.sock")
time.sleep(0.3)
s.recv(65536)

def cmd(c, wait=0.3):
    s.sendall((c + "\n").encode())
    time.sleep(wait)
    return s.recv(65536).decode()

def screen():
    out = cmd("xp /2000hx 0xb8000", 1.0)
    cells = [int(m, 16) for m in re.findall(r"0x([0-9a-f]{4})\b", out)]
    return "".join(chr(v & 0xff) if 32 <= (v & 0xff) < 127 else " " for v in cells)

ok = True
first = screen()
if "login:" not in first:
    print("FAIL: no login prompt on the VGA screen")
    ok = False
for k in ["r", "o", "o", "t", "ret", "ret"]:
    cmd("sendkey " + k, 0.2)
time.sleep(1.5)
second = screen()
if "login correct" not in second or "moonshot>" not in second:
    print("FAIL: the shell prompt was not reached after login")
    ok = False
# The shell must also serve a command, so echo a word and look for it twice,
# once as typed and once as printed.
for k in ["e", "c", "h", "o", "spc", "n", "o", "f", "b", "ret"]:
    cmd("sendkey " + k, 0.2)
time.sleep(1.0)
third = screen()
if third.count("nofb") < 2:
    print("FAIL: the shell did not serve the echo command")
    ok = False
sys.exit(0 if ok else 1)
PY
screen_rc=$?

# One page fault is expected, the deliberate demand-paging probe at 5GB.
log=nofb-serial.log
fail=0
[ "$src_rc" -eq 0 ] || fail=1
[ "$screen_rc" -eq 0 ] || fail=1
if ! grep -qE "^vga: char0=77 " $log; then
  echo "FAIL: the kernel did not boot the VGA fallback, so this is not a no-framebuffer boot"
  fail=1
fi
if grep "page fault:" $log | grep -v "addr=5368709120 " | grep -q .; then
  echo "FAIL: unexpected page fault in a boot without a framebuffer"
  grep "page fault:" $log | grep -v "addr=5368709120 " | sort | uniq -c | head -5
  fail=1
fi
if grep -qiE "panic|double fault|out of memory" $log; then
  echo "FAIL: panic or fatal error in a boot without a framebuffer"
  fail=1
fi
last_tick=$(grep -E "^tick [0-9]+" $log | tail -1 | awk '{print $2}')
if [ "${last_tick:-0}" -lt 300 ]; then
  echo "FAIL: ticks did not reach 300 (3 seconds), last tick ${last_tick:-none}"
  fail=1
fi
if ! grep -q "^\[raket\] session 0 password check uid=0 ok=1" $log; then
  echo "FAIL: the root login was not accepted"
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "--- $log ---"
  head -80 $log
  exit 1
fi
cleanup
trap restore EXIT

# The guard must not switch the bar off where it belongs. The ordinary kernel
# is built and booted with its framebuffer, and the bottom rows of the screen,
# where the status bar is, are captured twice after login, seconds apart. The bar
# counts uptime in seconds, so the two captures differ only if it still
# updates, and it must hold text, not only its background.
cd ..
if ! ./build.sh >/dev/null 2>&1; then
  echo "FAIL: building the ordinary kernel failed"
  exit 1
fi
cd out
isodir=isoroot-nofb-gfx
rm -rf "$isodir" nofb-gfx.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o nofb-gfx.iso "$isodir" >grub-mkrescue-nofb.log 2>&1
if [ ! -f nofb-gfx.iso ]; then
  echo "FAIL: grub-mkrescue did not produce nofb-gfx.iso"
  cat grub-mkrescue-nofb.log
  exit 1
fi
rm -f nofb-gfx-serial.log nofb.sock nofb_bar_*.ppm
qemu-system-x86_64 -cdrom nofb-gfx.iso \
  -serial file:nofb-gfx-serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:nofb.sock,server,nowait &
qemu_pid=$!
trap 'cleanup; restore' EXIT
sleep 4

python3 - <<'PY'
import socket, time, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("nofb.sock")
time.sleep(0.3)
s.recv(65536)

def bar(name):
    s.sendall(("screendump " + name + "\n").encode())
    time.sleep(1.0)
    s.recv(65536)
    data = open(name, "rb").read()
    head = data.split(b"\n", 3)
    w, h = map(int, head[1].split())
    rows = 16
    return w, h, head[3][(h - rows) * w * 3:h * w * 3]

# The bar is part of the desktop, which comes after the login screen.
for k in ["r", "o", "o", "t", "ret"]:
    s.sendall(("sendkey " + k + "\n").encode())
    time.sleep(0.1)
time.sleep(0.5)
s.sendall(b"sendkey ret\n")
time.sleep(1.5)
s.recv(65536)
w, h, first = bar("nofb_bar_1.ppm")
time.sleep(2.5)
_, _, second = bar("nofb_bar_2.ppm")
ok = True
colours = set(first[i:i + 3] for i in range(0, len(first), 3))
if w < 640 or h < 400:
    print("FAIL: the ordinary boot did not get a pixel framebuffer, %dx%d" % (w, h))
    ok = False
if len(colours) < 3:
    print("FAIL: the status bar holds no text, %d colours in its rows" % len(colours))
    ok = False
if first == second:
    print("FAIL: the status bar did not change in 2.5 seconds, so it no longer updates")
    ok = False
sys.exit(0 if ok else 1)
PY
gfx_rc=$?
cleanup
trap restore EXIT
glog=nofb-gfx-serial.log
if grep "page fault:" $glog | grep -v "addr=5368709120 " | grep -q .; then
  echo "FAIL: unexpected page fault in the ordinary framebuffer boot"
  gfx_rc=1
fi
if [ "$gfx_rc" -ne 0 ]; then
  exit 1
fi
echo "PASS: a boot without a framebuffer ran past tick $last_tick with no page fault, showed the login, reached the shell prompt and served a command, and the framebuffer boot still updates its status bar"
exit 0
