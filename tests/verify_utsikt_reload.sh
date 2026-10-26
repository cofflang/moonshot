#!/usr/bin/env bash
#
# verify_utsikt_reload.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Reloading a page gives the previous document back. Keeping every reloaded
# document in utsikt's 8MB heap for good would let a reader who
# presses r often enough run the browser out of memory.
#
# The heap is read from outside. The shell's `tasks` command reports each
# ring-3 task's live heap bytes and how far its frontier has ever moved, and
# writes the same line to serial. This reloads twice, reads it, reloads thirty
# more times and reads it again.
#
#   1. Live bytes are unchanged. The same document parsed again owns exactly
#      as much as before, so any growth is something kept by mistake.
#   2. The frontier moved by no more than one document's worth over thirty
#      reloads. With no reuse it would move by thirty. A document's worth is
#      the gap between the frontier and the live bytes after the first
#      reloads, which is the space the old document gave back. The live bytes
#      themselves are no measure, since most of them are the frame buffer.
#   3. lager refused no dealloc. It logs every pointer it will not take back,
#      so a block utsikt freed twice, or a name it did not own, shows up here
#      instead of as corruption somewhere else later.
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

sockfile=verify_utsikt_reload.sock
rm -f serial.log "$sockfile"
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

sleep 2

python3 - "$sockfile" <<'EOF'
import socket, sys, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.2)
sock.recv(65536)

def send(cmd, settle=0.06):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    try:
        sock.recv(65536)
    except BlockingIOError:
        pass

def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "_": "shift-minus"}
    typ([keymap.get(c, c) for c in s])

def reloads(n):
    for _ in range(n):
        typ(["r"])
        time.sleep(0.5)

def tasks():
    # utsikt has focus; the shell is one alt-tab away, and back again after.
    typ(["alt-tab"]); time.sleep(0.8)
    word("tasks"); typ(["ret"]); time.sleep(1.0)
    typ(["alt-tab"]); time.sleep(0.8)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.2)
word("start utsikt.elf"); typ(["ret"]); time.sleep(4.5)
typ(["alt-tab"]); time.sleep(1.5)

reloads(2)
tasks()
reloads(30)
tasks()
sock.close()
EOF

sleep 1

python3 - <<'PY'
import re
log = open("serial.log", "rb").read().decode("utf-8", "replace")
# serial_print writes a byte at a time and the scheduler's and timer's own
# lines can land between any two bytes of another line, including in the
# middle of a [tasks] report. Removing each of those messages together with
# the newline it printed puts the interrupted line back together. This is the
# same stream filter test_repl.sh uses, for the same reason.
log = re.sub(r"\[sched\] -> task \d+ \(counter=\d+\)\n", "", log)
log = re.sub(r"tick \d+\n", "", log)
ok = True

rows = re.findall(r"\[tasks\] task (\d+) heap:(\d+) top:(\d+)", log)
if len(rows) < 2:
    print("FAIL: expected two [tasks] heap reports, found %d" % len(rows))
    raise SystemExit(1)
(t1, h1, top1), (t2, h2, top2) = rows[0], rows[-1]
h1, top1, h2, top2 = int(h1), int(top1), int(h2), int(top2)
print("after 2 reloads:  task %s heap %d bytes live, frontier at %d" % (t1, h1, top1))
print("after 32 reloads: task %s heap %d bytes live, frontier at %d" % (t2, h2, top2))

if t1 != t2:
    print("FAIL: the two reports are about different tasks")
    ok = False
if h2 != h1:
    print("FAIL: live heap changed across 30 reloads of the same page (%+d bytes)" % (h2 - h1))
    ok = False
if top2 - top1 > top1 - h1:
    print("FAIL: the frontier moved %d bytes in 30 reloads, more than a document's worth (%d)"
          % (top2 - top1, top1 - h1))
    ok = False

refused = re.findall(r"\[lager\] dealloc: not a live block.*", log)
if refused:
    print("FAIL: lager refused %d dealloc(s), e.g. %s" % (len(refused), refused[0]))
    ok = False

panics = len(re.findall(r"PANIC", log))
# Not "page fault": the kernel takes one on purpose at every boot, testing
# demand paging, and logs it.
faults = len(re.findall(r"double fault", log, re.I))
if panics or faults:
    print("FAIL: panics %d, faults %d" % (panics, faults))
    ok = False

print()
if ok:
    print("PASS: reloading gives the old document back")
    raise SystemExit(0)
print("FAIL: reloading leaks")
raise SystemExit(1)
PY
