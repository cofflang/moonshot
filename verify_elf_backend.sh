#!/usr/bin/env bash
#
# verify_elf_backend.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Runs coff's ring-3 output on the real kernel and checks the answers.
#
# This began as the only verification the `--elf` machine-code backend had:
# c0-coff's differential suite compares coff against coff0.c, and coff0.c had
# only the text backend, so nothing checked the path every ring-3 binary was
# built through, and three silent-wrong-code bugs were found in it by eye (a
# label collision that sent false branches into function epilogues, arg4
# passed in rcx instead of r10, miscompiled && / ||). That backend is now
# gone: --elf is the text backend with Moonshot's syscall numbers,
# coff0.c has the same target, and run_tests.sh diffs the two over every
# ring-3 program. What this script still proves is the part no diff can: that
# the target's syscall sequences, smed's image and the kernel's loader agree,
# end to end, with real exit codes.
#
# Each program in elf_tests/ computes a value that only comes out right if
# codegen is correct and returns it, with the expected value written next to
# it as `// expect: N`. gen_elf_tests.sh compiles them all with `coff --elf`
# and bakes them into the kernel as etNN.elf; this script boots once, spawns
# each in turn, and checks the exit code the kernel prints to serial.
#
# A wrong answer here is a compiler bug, not a kernel bug -- which is the
# whole point of keeping the programs small and arithmetic.

set -u
cd "$(dirname "$0")"

# Regenerate first: the checked-in elf_tests_data.c0 is only as fresh as the
# last run, and a stale one would test the previous compiler's output.
./gen_elf_tests.sh || exit 1

./build.sh || exit 1

manifest=elf_tests/manifest.txt
if [ ! -f "$manifest" ]; then
  echo "FAIL: gen_elf_tests.sh produced no manifest"
  exit 1
fi

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
if [ ! -f moonshot.iso ]; then
  echo "FAIL: grub-mkrescue did not produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

# A fresh disk every run. jakel now re-seeds its fixtures on every boot, so a
# reused disk.img would no longer serve stale binaries -- but starting clean
# keeps the run deterministic (a known node count, no leftovers from whatever
# ran last), which matters for a suite whose whole job is to be trustworthy.
rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

sockfile=verify_elf_backend.sock
rm -f serial.log "$sockfile"
qemu-system-x86_64 -cdrom moonshot.iso \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

sleep 3

names=$(awk '{print $1}' "$manifest")

python3 - "$sockfile" $names <<'EOF'
import socket, sys, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
time.sleep(0.2)
sock.recv(65536)

def send(cmd, settle=0.05):
    sock.sendall((cmd + "\n").encode())
    time.sleep(settle)
    sock.recv(65536)

def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

def word(s):
    # No bare `sendkey _` exists in QEMU's monitor, and a dropped character
    # would silently spawn the wrong filename -- so test ELFs are named
    # etNN.elf, using only characters that map.
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
    typ([keymap.get(c, c) for c in s])

# raket login gate.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.5)

# spawn3, not run3. run3 executes in the CALLING task, so the program's
# SYS_EXIT marks the shell's own task EXITED and the shell is gone -- the
# first test would run and the other six would have nothing left to type
# into. spawn3 runs each program in its own task instead.
#
# Each spawn opens a tavla, so close it before the next one: Alt+Tab onto it,
# Alt+W to close. Without that the layout fills after four and later spawns
# get no window. It also keeps the run honest about the orphaned-tavla path,
# since by then the program has already exited.
for name in sys.argv[2:]:
    word("spawn3 test/%s.elf" % name)
    typ(["ret"])
    time.sleep(2.0)
    send("sendkey alt-tab", settle=0.4)
    send("sendkey alt-w", settle=0.6)
    time.sleep(0.5)

sock.close()
EOF

sleep 2

ok=1
pass=0
fail=0

echo "--- exit codes seen ---"
grep '\[syscall\] exit code=' serial.log || true
echo

# Exit codes appear in spawn order, so walk both lists together rather than
# grepping for each value: two tests could legitimately share a code, and a
# missing run would otherwise shift every later match without being noticed.
mapfile -t codes < <(grep -o '\[syscall\] exit code=-\?[0-9]*' serial.log | sed 's/.*=//')

i=0
while read -r name src expect; do
  got="${codes[$i]:-<none>}"
  if [ "$got" = "$expect" ]; then
    printf "  PASS  %-24s exit %s\n" "$src" "$got"
    pass=$((pass + 1))
  else
    printf "  FAIL  %-24s expected %s, got %s\n" "$src" "$expect" "$got"
    fail=$((fail + 1))
    ok=0
  fi
  i=$((i + 1))
done < "$manifest"

total=$(wc -l < "$manifest")
echo
echo "$pass/$total correct, $fail wrong"

panics=$(grep -c 'PANIC' serial.log || true)
dfs=$(grep -c 'double fault' serial.log || true)
echo "panics: $panics, double faults: $dfs"
if [ "$panics" -ne 0 ] || [ "$dfs" -ne 0 ]; then
  echo "FAIL: crash during the run"
  ok=0
fi

echo
if [ "$ok" -eq 1 ]; then
  echo "PASS: coff --elf target verified — $total programs compiled for ring 3,"
  echo "  assembled by smed, run on the kernel, every exit code correct"
  exit 0
fi
echo "FAIL: coff --elf backend produced wrong code"
exit 1
