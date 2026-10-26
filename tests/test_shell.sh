#!/usr/bin/env bash
#
# test_shell.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Shell process-model lifecycle test. It drives skalman's `start` and `kill`
# builtins via QEMU `sendkey` and proves both reach chrone at runtime, using
# the shell's and the scheduler's own serial lines as the witness.
#
#   start test/mouse.elf -> a new task, a program that runs until something
#            stops it. Its id is read from the scheduler's serial line, so
#            the test does not depend on slot numbering.
#   tasks -> lists task N.
#   kill N -> "killed task N", after which the reaper frees its stack and
#            its address space ([sched] reaped task N, freed address space of
#            task N), and a second start fits again.
#   count -> a file whose one line has no newline after it is 1 line, 2
#            words, 7 bytes.
#
# Same "inject a real key event, check the real output" approach as
# test_keyboard.sh, one layer up (the whole process lifecycle).
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

rm -f serial.log shell_test.sock
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:shell_test.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f shell_test.sock; }
trap cleanup EXIT

sleep 2

python3 - <<'EOF2'
import socket, time, re

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("shell_test.sock")
time.sleep(0.2)
s.recv(4096)  # discard QEMU monitor banner

def word(text, gap=0.08):
    for c in text:
        k = {" ": "spc", "\n": "ret", ".": "dot", "/": "slash"}.get(c, c)
        s.sendall(("sendkey %s\n" % k).encode())
        time.sleep(gap)
        s.recv(4096)

word("root\n"); time.sleep(0.5)
word("\n"); time.sleep(1.0)

word("start test/mouse.elf\n"); time.sleep(2.0)
with open("serial.log", errors="replace") as f:
    # The scheduler's own line, since a [sched] line written mid-way through
    # the shell's mirrored output can cut the shell's "started task N".
    m = re.findall(r"^\[sched\] spawned task (\d+) ", f.read(), re.M)
tid = m[-1] if m else "0"
with open("shell_spawn_id.txt", "w") as f:
    f.write(tid)
word("tasks\n"); time.sleep(1.0)
word("kill %s\n" % tid); time.sleep(1.5)
# The reaper only runs on a scheduler tick with another task to run, and
# the shell waits for keys, so give it something to do.
word("start test/mouse.elf\n"); time.sleep(2.0)
word("write cnt.txt one two\n"); time.sleep(0.5)
word("count cnt.txt\n"); time.sleep(0.8)
s.close()
EOF2

sleep 1

ok=1
tid=$(cat shell_spawn_id.txt 2>/dev/null || echo none)
grep -aqE "^\[sh\] task ${tid} (run|blk|cur) " serial.log || { echo "tasks did not list task $tid"; ok=0; }
grep -aqE "^\[sh\] killed task ${tid}$" serial.log || { echo "no 'killed task $tid'"; ok=0; }
kill_line=$(grep -anE "^\[sh\] killed task ${tid}$" serial.log | head -1 | cut -d: -f1)
reaped=$(grep -anE "^\[sched\] reaped task ${tid} " serial.log | awk -F: -v L="${kill_line:-0}" '$1 > L' | head -1)
freed=$(grep -anE "^\[sched\] freed address space of task ${tid}," serial.log | awk -F: -v L="${kill_line:-0}" '$1 > L' | head -1)
[ -n "$reaped" ] || { echo "task $tid was not reaped after the kill"; ok=0; }
[ -n "$freed" ] || { echo "task $tid's address space was not freed"; ok=0; }
again=$(grep -anE "^\[sched\] spawned task [0-9]+ " serial.log | awk -F: -v L="${kill_line:-0}" '$1 > L' | head -1)
[ -n "$again" ] || { echo "the second start failed"; ok=0; }
grep -aqE "^\[sh\] 1 line, 2 words, 7 bytes$" serial.log || { echo "count did not say 1 line, 2 words, 7 bytes"; ok=0; }

if [ "$ok" -eq 1 ]; then
  echo "PASS: start ran task $tid, tasks listed it, kill $tid stopped it, the reaper freed it, and a second start fit"
  grep -aE "^\[sh\] killed task|^\[sched\] (spawned task|reaped task ${tid} |freed address space of task ${tid},)" serial.log | tail -n +6
  exit 0
fi
echo "FAIL: start/kill/reap lifecycle not proven (task ${tid})"
grep -aE "^\[sh\]|^\[sched\] (spawned|reaped|freed)" serial.log | tail -30
exit 1
