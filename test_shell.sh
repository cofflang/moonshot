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
# Shell process-model lifecycle test: drives skalman's `spawn` and `kill`
# builtins via QEMU `sendkey` and proves BOTH reach chrone at runtime, using the
# scheduler's own serial log as the witness:
#
#   spawn -> a new task id (the first FREE slot, which is 3 after slot reuse
#            recycles the boot exiter's slot) appears in [sched] output. The
#            spawned id is detected dynamically from the serial log so this
#            test stays valid regardless of future slot-numbering changes.
#   kill N -> task N STOPS appearing: after its last [sched] line, many more
#            switches happen (to other tasks) with N never again -- proof `kill`
#            marked it EXITED and sched_pick_next now skips it.
#
# Same "inject a real key event, check the real output" approach as
# test_keyboard.sh, one layer up (the whole process lifecycle).
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

rm -f serial.log shell_test.sock
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:shell_test.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }
trap cleanup EXIT

# Reach the interrupt-enabled shell prompt, and let the boot-time exiter task
# (task 3) run its 3 quanta and exit first, so the table state is settled.
sleep 2

python3 - <<'EOF'
import socket, time, re

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("shell_test.sock")
time.sleep(0.2)
s.recv(4096)  # discard QEMU monitor banner

def typ(word_keys, gap=0.3):
    for k in word_keys:
        s.sendall(("sendkey %s\n" % k).encode())
        time.sleep(gap)
        s.recv(4096)

# "spawn" + Enter, then give the new task ~1.5s to actually get scheduled.
typ(["s", "p", "a", "w", "n", "ret"])
time.sleep(1.5)

# Detect which task id was spawned by reading the serial log: boot spawns
# tasks 0-4 (workers + shell task), so our shell-initiated spawn is the 6th
# "[sched] spawned task" entry. The last such line in the log is ours.
with open("serial.log") as f:
    content = f.read()
spawns = re.findall(r"\[sched\] spawned task (\d+)", content)
our_id = int(spawns[-1]) if len(spawns) >= 6 else 4  # fallback to 4

# Write for bash verification to consume.
with open("shell_spawn_id.txt", "w") as f:
    f.write(str(our_id))

# Kill the spawned task by its actual id.
kill_keys = ["k", "i", "l", "l", "spc"] + list(str(our_id)) + ["ret"]
typ(kill_keys)
s.close()
EOF

# Let the scheduler run well past the kill so there are plenty of post-kill
# switches to confirm task 4 is gone for good.
sleep 3

ok=1

# Read the dynamically-detected spawned task id (written by the Python above).
# Falls back to 4 if the file isn't there (shouldn't happen in normal runs).
shell_id=$(cat shell_spawn_id.txt 2>/dev/null || echo 4)

# spawn: the shell-initiated task must have appeared in the scheduler log.
if ! grep -qE "^\[sched\] -> task ${shell_id} \(counter=[0-9]+\)$" serial.log; then
  ok=0
fi

# reclaim/reuse: the boot exiter (task 3) is reaped BEFORE the shell spawn,
# freeing its page. Because pmm's free list is LIFO and nothing else frees a
# page in between, the shell's spawn must get that exact page back. With slot
# reuse enabled, the shell's spawn lands in slot 3 (the just-freed slot) and
# gets the same page address. The LAST "spawned task <shell_id>" line (tail -1)
# is ours -- the first would be the boot-time spawn of that slot (if reused).
reap3_stack=$(grep -oE "^\[sched\] reaped task 3 stack=[0-9]+$" serial.log | head -1 | grep -oE "[0-9]+$")
spawn_shell_stack=$(grep -oE "^\[sched\] spawned task ${shell_id} stack=[0-9]+$" serial.log | tail -1 | grep -oE "[0-9]+$")
if [ -z "$reap3_stack" ] || [ "$reap3_stack" != "$spawn_shell_stack" ]; then ok=0; fi

# kill also feeds the reaper: after `kill N`, task N must itself be reaped.
if ! grep -qE "^\[sched\] reaped task ${shell_id} stack=[0-9]+$" serial.log; then ok=0; fi

# kill: after the spawned task's LAST scheduler appearance, there must be many
# more switches (to other tasks) and none of them the spawned task -- proof
# `kill` marked it EXITED and sched_pick_next now skips it.
last_tS=$(grep -nE "^\[sched\] -> task ${shell_id} \(counter=[0-9]+\)$" serial.log | tail -1 | cut -d: -f1)
after=0
if [ -z "$last_tS" ]; then
  ok=0
else
  after=$(grep -nE "^\[sched\] -> task [0-9]+ \(counter=[0-9]+\)$" serial.log \
    | awk -F: -v L="$last_tS" '$1 > L' | wc -l)
  [ "$after" -ge 10 ] || ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: shell spawn/kill/reap lifecycle proven -- task ${shell_id} ran, reused task 3's reaped page ($spawn_shell_stack), 'kill ${shell_id}' stopped it ($after later switches, never rescheduled), and it was reaped"
  echo "--- task ${shell_id}'s life + reclaim ---"
  grep -nE "^\[sched\] (spawned task ${shell_id}|reaped task [3${shell_id}]) " serial.log
  grep -nE "^\[sched\] -> task ${shell_id} " serial.log | sed -n '1p;$p'
  exit 0
else
  echo "FAIL: spawn/kill/reap lifecycle not proven (shell_id=${shell_id} last='${last_tS:-none}' after='${after:-0}' reap3='${reap3_stack:-none}' spawn='${spawn_shell_stack:-none}')"
  echo "--- [sched] lines ---"
  grep -E "^\[sched\]" serial.log | tail -30
  exit 1
fi
