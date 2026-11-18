#!/usr/bin/env bash
#
# verify_hostile_syscalls.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Calls every syscall from ring 3 with the arguments a hostile program would
# choose, the hostile syscall cases. Null, kernel half,
# non-canonical and unmapped pointers, a pointer whose end wraps, negative and
# huge lengths, bad handles and bad task ids. The program is
# tests/elf/29_hostile_syscalls.c0.
#
#   tests/verify_hostile_syscalls.sh            the cases that hold, in the suite
#   tests/verify_hostile_syscalls.sh known      the open findings, not in the suite
#   tests/verify_hostile_syscalls.sh case N...  the numbered cases, one boot each
#
# What the suite run checks, with every case below 100 run one after the other
# in a single boot.
#
#   1. Every case holds, the kernel answers each hostile call with an error
#      or with nothing, and the program reaches its end.
#   2. A second copy of the program, started before the first case, kept a
#      canary in its own memory and in a file the whole time, and found both
#      unchanged when the last case was done.
#   3. The kernel did not panic, fault or run out of room, and no syscall
#      found interrupts on where its pointer checks need them off. The cases
#      call every syscall that reads or writes a program's memory, so this is
#      the guard on that assertion (user_assert_irq_off in syscall.c0).
#   4. The shell still answers.
#
# Cases from 100 on each expose a known open finding. They are listed
# in KNOWN below with the finding they show and are not run by the suite,
# some of them stop the kernel. Each runs alone in a boot of its own. A case
# satisfying the acceptance checks in KNOWN is a classification error and
# makes the script exit 1. Accepted cases belong below 100.
set -u
cd "$(dirname "$0")/.."

FAULTS='PANIC|double fault|page fault|general protection|out of memory'

# case number, finding, what the case shows
KNOWN=(
  "114 S3-09 wait on a task this program did not start reveals its exit code"
)

mode=suite
case "${1:-}" in
  known) mode=known ;;
  case) mode=case; shift ;;
  "") ;;
  *) echo "usage: $0 [known | case N...]"; exit 2 ;;
esac
cases=()
if [ "$mode" = known ]; then
  for k in "${KNOWN[@]}"; do cases+=("${k%% *}"); done
elif [ "$mode" = case ]; then
  cases=("$@")
  [ "${#cases[@]}" -gt 0 ] || { echo "FAIL: no cases to run"; exit 2; }
  for n in "${cases[@]}"; do
    if ! [[ "$n" =~ ^([1-9]|[1-4][0-9]|5[0-9]|114)$ ]]; then
      echo "FAIL: no such case $n"; exit 2
    fi
  done
fi

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

sockfile=verify_hostile_syscalls.sock
qemu_pid=
cleanup() {
  [ -n "$qemu_pid" ] && { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }
  rm -f "$sockfile"
}
trap cleanup EXIT

wait_for_socket() {
  local i
  for i in $(seq 1 300); do
    [ -S "$sockfile" ] && return 0
    sleep 0.1
  done
  echo "FAIL: QEMU monitor socket did not appear within 30 s"
  return 1
}

# Boots a fresh machine, logs in, starts the program with the arguments given
# (all runs every case below 100) and waits for it to end, for the kernel to stop, or
# for the time limit. Then types a command at the shell and sees whether it
# answers. Leaves what the machine printed in serial.log and one line of
# the outcome in outcome.txt.
boot_and_run() { # limit-seconds [argument]
  rm -f serial.log "$sockfile" outcome.txt
  rm -f disk.img
  dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
  qemu-system-x86_64 -cdrom moonshot.iso \
    -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
    -serial file:serial.log -display none -no-reboot -m 128 \
    -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
    -monitor unix:"$sockfile",server,nowait &
  qemu_pid=$!
  wait_for_socket || return 1
  sleep 3
  python3 - "$sockfile" "$1" "${2:-}" <<'PY' || return 1
import socket, sys, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
sock.setblocking(False)
limit = float(sys.argv[2])
arg = sys.argv[3]
time.sleep(0.2)

def drain():
    try:
        sock.recv(65536)
    except BlockingIOError:
        pass

def send(cmd, settle=0.05):
    try:
        sock.sendall((cmd + "\n").encode())
    except OSError:
        return
    time.sleep(settle)
    drain()

def typ(keys, gap=0.04):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])

def serial():
    try:
        with open("serial.log", "rb") as f:
            return f.read()
    except OSError:
        return b""

STOP = (b"PANIC", b"double fault", b"page fault", b"general protection", b"out of memory")

def stopped(text):
    return any(s in text for s in STOP)

word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.5)

start = len(serial())
word("start test/et29.elf" + (" " + arg if arg else "")); typ(["ret"])
t0 = time.time()
how = "timeout"
while time.time() - t0 < limit:
    text = serial()[start:]
    if stopped(text):
        how = "kernel stopped"
        break
    if b"[hostile] end" in text:
        how = "ended"
        break
    time.sleep(0.2)

if how == "ended":
    send("sendkey alt-tab", settle=0.3)
    send("sendkey alt-w", settle=0.4)
    time.sleep(0.5)
    word("echo hostile alive"); typ(["ret"])
    t1 = time.time()
    while time.time() - t1 < 6:
        if b"[sh] hostile alive" in serial():
            break
        time.sleep(0.2)
open("outcome.txt", "w").write(how + "\n")
open("mark.txt", "w").write(str(start) + "\n")
sock.close()
PY
  kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; qemu_pid=
  rm -f "$sockfile"
  # The boot self-tests print a page fault line of their own, so every check
  # reads only what came after the login.
  tail -c +$(($(cat mark.txt) + 1)) serial.log > run.log
}

ok=1

if [ "$mode" = suite ]; then
  boot_and_run 90 all || exit 1
  how=$(cat outcome.txt)
  echo "--- cases ---"
  grep -aE '^\[hostile\] [0-9]+ (pass|FAIL)' run.log
  echo
  total=$(grep -acE '^\[hostile\] [0-9]+ (pass|FAIL)' run.log)
  passed=$(grep -acE '^\[hostile\] [0-9]+ pass$' run.log)
  echo "$passed/$total cases hold, run $how"
  if [ "$how" != ended ]; then echo "FAIL: the run did not end ($how)"; ok=0; fi
  if [ "$total" -eq 0 ] || [ "$passed" -ne "$total" ]; then echo "FAIL: a case did not hold"; ok=0; fi
  ids=$(grep -aE '^\[hostile\] [0-9]+ (pass|FAIL)' run.log | cut -d' ' -f2)
  if [ "$ids" != "$(seq 1 59)" ]; then
    echo "FAIL: expected cases 1 through 59 exactly once, in order"; ok=0
  fi
  if ! grep -aq '^\[hostile\] canary kept$' run.log; then
    echo "FAIL: the canary program found its memory or its file changed, or never finished"; ok=0
  fi
  if grep -aqE "$FAULTS" run.log; then
    echo "FAIL: the kernel faulted"
    grep -aE "$FAULTS" run.log | head -5
    ok=0
  fi
  if grep -aq 'interrupts on in' run.log; then
    echo "FAIL: a syscall ran with interrupts on"
    grep -a 'interrupts on in' run.log | head -3
    ok=0
  fi
  if ! grep -aq '^\[sh\] hostile alive$' run.log; then echo "FAIL: the shell did not answer afterwards"; ok=0; fi
  if [ "$ok" -eq 1 ]; then
    echo "PASS: $passed hostile syscall cases refused or survived, the canary was untouched and the shell answers"
    exit 0
  fi
  exit 1
fi

# known and case, one boot for each number.
for n in "${cases[@]}"; do
  if [ "$mode" = known ]; then
    if [ "$n" -lt 100 ]; then echo "FAIL: known case $n is below 100"; ok=0; continue; fi
  fi
  boot_and_run 15 "$n" || exit 1
  how=$(cat outcome.txt)
  line=$(grep -aE "^\[hostile\] $n (pass|FAIL)" run.log | head -1)
  fault=$(grep -aE "$FAULTS" run.log | head -1)
  alive=no
  grep -aq '^\[sh\] hostile alive$' run.log && alive=yes
  held=no
  case "$line" in *" pass") held=yes ;; esac
  finding=
  for k in "${KNOWN[@]}"; do [ "${k%% *}" = "$n" ] && finding=$(echo "$k" | cut -d' ' -f2); done
  echo "case $n ${finding:+($finding)}: ${line:-no result line}; run $how; kernel ${fault:-no fault}; shell answers $alive"
  if [ "$mode" = case ]; then
    if [ "$held" != yes ] || [ "$how" != ended ] || [ "$alive" != yes ] || [ -n "$fault" ]; then
      echo "  FAIL: the requested case did not hold"
      ok=0
    fi
  elif ! grep -aqE "^\[hostile\] $n [a-z_]+" run.log; then
    echo "  FAIL: the known case never started"
    ok=0
  elif [ -z "$line" ] && [ -z "$fault" ]; then
    echo "  FAIL: no result or kernel fault confirms the known finding"
    ok=0
  fi
  if [ "$mode" = known ] && [ "$held" = yes ] && [ "$alive" = yes ] && [ -z "$fault" ]; then
    echo "  now holds, move it below 100 and out of KNOWN"
    ok=0
  fi
done
[ "$ok" -eq 1 ] || exit 1
exit 0
