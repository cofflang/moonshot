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
# c0-coff's differential suite compares coff against coff0.c over every
# ring-3 program, since --elf is the text backend with Moonshot's syscall
# numbers and coff0.c has the same target. What this script proves is the
# part no diff can, that
# the target's syscall sequences, smed's image and the kernel's loader agree,
# end to end, with real exit codes.
#
# Each program in tests/elf/ computes a value that only comes out right if
# codegen is correct and returns it, with the expected value written next to
# it as `// expect: N`. gen_elf_tests.sh compiles them all with `coff --elf`
# and bakes them into the kernel as etNN.elf; this script boots once, spawns
# each in turn, and checks the exit code the kernel prints to serial.
#
# A wrong answer here is a compiler bug, not a kernel bug -- which is the
# whole point of keeping the programs small and arithmetic.
#
# The machine has a Sound Blaster 16 (playing into nothing) because
# 13_oljud.c0 checks sound()'s answers, which need a card. What it actually
# plays is verify_oljud.sh's business.

set -u
cd "$(dirname "$0")/.."

# Regenerate first, since the packed tests are only as fresh as the
# last run, and a stale one would test the previous compiler's output.
./tools/gen_elf_tests.sh || exit 1

./build.sh || exit 1

manifest=$(pwd)/tests/elf/manifest.txt
if [ ! -f "$manifest" ]; then
  echo "FAIL: gen_elf_tests.sh produced no manifest"
  exit 1
fi

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

# A fresh disk every run. jakel re-seeds its fixtures on every boot, so a
# reused disk.img would not serve stale binaries -- but starting clean
# keeps the run deterministic (a known node count, no leftovers from whatever
# ran last), which matters for a suite whose whole job is to be trustworthy.
rm -f disk.img
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

sockfile=verify_elf_backend.sock
rm -f serial.log "$sockfile"
qemu-system-x86_64 -cdrom moonshot.iso \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
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

def typ(keys, gap=0.04):
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

# start, not run3. run3 (a debug command) runs in the CALLING task, so the
# program's SYS_EXIT marks the shell's own task EXITED and the shell is gone -- the
# first test would run and the other six would have nothing left to type
# into. start runs each program in its own task instead.
#
# Each spawn opens a tavla, so close it before the next one. Alt+Tab onto it,
# Alt+W to close. Without that the layout fills after four and later spawns
# get no window. It also keeps the run honest about the orphaned-tavla path,
# since by then the program has already exited.
# Counts exit lines incrementally, since serial.log grows to megabytes of
# scheduler lines, and rereading it whole every poll cost more time than the
# fixed sleeps this replaced. A marker split across two reads is caught by
# keeping the last few bytes of the previous read.
seen = {"pos": 0, "count": 0, "tail": b""}
def exits():
    try:
        with open("serial.log", "rb") as f:
            f.seek(seen["pos"])
            new = f.read()
    except OSError:
        return seen["count"]
    seen["pos"] += len(new)
    chunk = seen["tail"] + new
    marker = b"[syscall] exit code="
    seen["count"] += chunk.count(marker)
    keep = len(marker) - 1
    tail = chunk[-keep:] if len(chunk) >= keep else chunk
    # A marker already counted must not be counted again from the tail.
    seen["tail"] = b"" if marker in tail else tail
    return seen["count"]

for name in sys.argv[2:]:
    # Two arguments for every test, since 16_args_sleep checks it receives them,
    # and the rest never look.
    # Wait for this program's exit line on serial rather than a fixed two
    # seconds; most finish in a fraction of that. 16_args_sleep sleeps half
    # a second and 13_oljud plays sound for several, hence the long limit.
    # Counted BEFORE the command is typed, since a fast program has exited before
    # typing returns, and counting after it would wait for an exit that
    # already happened.
    before = exits()
    word("start test/%s.elf one two" % name)
    typ(["ret"])
    t0 = time.time()
    while exits() == before and time.time() - t0 < 15:
        time.sleep(0.1)
    send("sendkey alt-tab", settle=0.3)
    send("sendkey alt-w", settle=0.4)
    time.sleep(0.2)

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
# grepping for each value, since two tests could legitimately share a code, and a
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
