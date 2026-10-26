#!/usr/bin/env bash
#
# verify_scripts.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# skalman scripts (sk_script.c0), the files tests/elf/22_scripts.c0 writes.
#
#   1. while with arithmetic counts down, then the line after the loop runs.
#   2. if, else if and else pick by $# and $1, numbers and strings, + joins
#      strings, ! and || work.
#   3. An empty then-branch goes to its else, and a branch that ran skips the
#      else.
#   4. A line that does not parse stops the script with its file and line.
#   5. A loop that never ends is stopped after 100000 steps.
#   6. A script runs another with run.
#   7. At the prompt, name = expression sets a variable and $name uses it.
set -u
cd "$(dirname "$0")/.."

./tools/gen_elf_tests.sh >/dev/null || exit 1
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

sockfile=verify_scripts.sock
rm -f serial.log "$sockfile" scripts_*.ppm
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
def typ(keys, gap=0.07):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)
def word(s):
    keymap = {".": "dot", " ": "spc", "-": "minus", "/": "slash", "$": "shift-4",
              "*": "shift-8", "=": "equal"}
    typ([keymap.get(c, c) for c in s])
def line(s, wait=0.8):
    word(s); typ(["ret"]); time.sleep(wait)

line("root", 0.5); typ(["ret"]); time.sleep(1.2)
line("start test/et22.elf", 2.0)
line("run test/count.sk")
line("run test/args.sk")
line("run test/args.sk hi")
line("run test/args.sk a b")
line("run test/empty.sk")
line("run test/bad.sk")
line("run test/loop.sk", 6.0)
line("run test/outer.sk", 1.5)
line("x = 5 * 2")
line("echo x is $x")
sock.close()
PY
sleep 1

ok=1
# The timer's "tick N" lines can land in the middle of another line.
clean=$(python3 -c 'import re,sys; sys.stdout.write(re.sub(r"tick \d+\n", "", open("serial.log", errors="replace").read()))')
got=$(echo "$clean" | grep -aE '^\[sh\] |^\[run\] ' | grep -v '^\[sh\] prompt$' | sed 's/^\[sh\] //')
expected='n is 3
n is 2
n is 1
done
no arguments
total 13
moonshot
greeting hi
total 13
moonshot
other a and b
total 13
moonshot
else ran
then ran
run: test/bad.sk:1: an expression was expected
[run] test/bad.sk:1: an expression was expected
run: test/loop.sk:2: stopped after 100000 steps
[run] test/loop.sk:2: stopped after 100000 steps
outer starts
n is 3
n is 2
n is 1
done
outer ends
x is 10'
# Only the lines from the first script on, since the boot and the test
# program print their own.
got=$(echo "$got" | sed -n '/^n is 3$/,$p')
if [ "$got" = "$expected" ]; then
  echo "PASS: scripts loop, branch, compute, report errors, stop runaways and nest"
  exit 0
fi
echo "FAIL: the scripts printed"
diff <(echo "$expected") <(echo "$got")
exit 1
