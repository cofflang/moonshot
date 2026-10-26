#!/usr/bin/env bash
#
# verify_kill_sleeper.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# A program closed with Alt+W stays closed. Infecteria draws frame after
# frame, so the W that closes it often lands while it runs. It then goes on
# to its next call, often a sleep, which must not make it runnable again.
# Alt is held down first, the way a person types it, a little longer each
# time, since QEMU's own alt-w presses both keys at once.
#
#   1. Every Infecteria started and closed this way is reaped, its slot
#      freed, five times over.
#   2. The scheduler never switches to a closed Infecteria again.
set -u
cd "$(dirname "$0")/.."

./build.sh || exit 1

mkdir -p out && cd out

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
if [ ! -f moonshot.iso ]; then
  echo "FAIL: grub-mkrescue did not produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

sockfile=verify_kill_sleeper.sock
rm -f serial.log "$sockfile"
rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT
sleep 3

python3 - "$sockfile" <<'PY'
import socket, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.3)
sock.recv(65536)
def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    sock.recv(65536)
def typ(keys, gap=0.08):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)
def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])
def mark(s):
    word("echo " + s); typ(["ret"]); time.sleep(0.5)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
for d in (0.01, 0.02, 0.03, 0.04, 0.05):
    word("start infecteria.elf"); typ(["ret"]); time.sleep(2.0)
    typ(["alt-tab"]); time.sleep(0.5)
    sock.sendall(b"sendkey alt 400\n")
    time.sleep(d)
    send("sendkey alt-w")
    time.sleep(1.0)
mark("closed")
time.sleep(1.0)
mark("settled")
mark("done")
sock.close()
PY
sleep 1

ok=1
killed=$(grep -aoE '\[tavla\] closed win=[0-9]+ killed task=[0-9]+' serial.log | sed 's/.*task=//')
echo "killed tasks: $(echo $killed)"
if [ "$(echo "$killed" | grep -c .)" != "5" ]; then
  echo "FAIL: expected five Infecteria windows closed by Alt+W"; ok=0
fi
# Each kill must be followed by the reaper freeing that slot, before the
# next Infecteria starts.
awk -v want=5 '
  /\[tavla\] closed win=[0-9]+ killed task=/ { sub(/.*task=/, ""); pend = $0 + 0; open = 1; next }
  open && /\[sched\] reaped task / { t = $4 + 0; if (t == pend) { reaped++; open = 0 } }
  open && /\[sched\] -> task / { t = $4 + 0; if (t == pend) { back++ } }
  /\[sh\] settled$/ { settled = 1 }
  END {
    printf "reaped %d of %d, switched to a closed task %d times\n", reaped, want, back
    exit !(reaped == want && back == 0)
  }' serial.log || { echo "FAIL: a closed Infecteria was not reaped, or ran again"; ok=0; }
if ! grep -aq '^\[sh\] done$' serial.log; then
  echo "FAIL: the shell did not reach the end of the script"; ok=0
fi
if [ "$ok" -eq 1 ]; then
  echo "PASS: Infecteria closed with Alt+W is reaped every time and never runs again"
  exit 0
fi
exit 1
