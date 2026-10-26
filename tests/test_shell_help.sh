#!/usr/bin/env bash
#
# test_shell_help.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# The shell's command table. `help`, `help (command)` and Tab completion all
# read it, and the debug commands are in it only in a MOONSHOT_DEBUG=1
# build. Two boots, read through the shell's [sh] serial mirror.
#
#   ordinary build
#     help start      prints start's usage and what it does
#     help interpret  likewise
#     inte<Tab>       completes to "interpret ", which then runs demo.c0
#     chars           unknown, and help lists no debug commands
#   debug build
#     chars           prints the glyph grid
#     help run3       is marked as a debug command
set -u
cd "$(dirname "$0")/.."

mkdir -p out && cd out

sockfile=shell_help.sock
qemu_pid=0
cleanup() { [ "$qemu_pid" -ne 0 ] && kill "$qemu_pid" 2>/dev/null; wait 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

boot() { # serial-log, then one shell line per argument (\t is Tab)
  local log=$1
  shift
  isodir=isoroot
  rm -rf "$isodir" moonshot.iso
  mkdir -p "$isodir/boot/grub"
  cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
  cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
  grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
  rm -f "$sockfile" "$log"
  qemu-system-x86_64 -cdrom moonshot.iso \
    -serial file:"$log" -display none -no-reboot -m 128 \
    -monitor unix:"$sockfile",server,nowait &
  qemu_pid=$!
  sleep 3
  python3 - "$sockfile" "$@" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.3)
def keys(text):
    for c in text:
        name = {" ": "spc", "\n": "ret", "\t": "tab", ".": "dot", "-": "minus", "/": "slash"}.get(c, c)
        s.send(("sendkey %s\n" % name).encode())
        time.sleep(0.05)
keys("root\n"); time.sleep(1)
keys("\n"); time.sleep(1.2)
for line in sys.argv[2:]:
    keys(line.replace("\\t", "\t") + "\n")
    time.sleep(1.2)
time.sleep(0.5)
s.close()
PY
  kill "$qemu_pid" 2>/dev/null
  wait "$qemu_pid" 2>/dev/null
  qemu_pid=0
}

ok=1
check() { # description, log, extended regex
  if grep -aqE "$3" "$2"; then echo "ok    $1"; else echo "FAIL  $1"; ok=0; fi
}
check_not() {
  if grep -aqE "$3" "$2"; then echo "FAIL  $1"; ok=0; else echo "ok    $1"; fi
}

../build.sh >/dev/null || { echo "FAIL: build"; exit 1; }
boot serial.log "help" "help start" "help interpret" 'inte\tdemo.c0' "chars"
cp serial.log shell_help_plain.log
check "help start explains start" serial.log '^\[sh\]   run a program in a window of its own'
check "help interpret explains interpret" serial.log '^\[sh\]   run a c0 source file through the interpreter'
check "Tab completes inte to interpret, which runs demo.c0" serial.log '^\[repl\] 1887$'
check "chars is unknown in an ordinary build" serial.log '^\[sh\] unknown command: chars$'
check_not "help lists no debug commands" serial.log '^\[sh\] debug commands'

MOONSHOT_DEBUG=1 ../build.sh >/dev/null || { echo "FAIL: debug build"; exit 1; }
boot serial.log "help" "chars" "help run3"
check "help lists the debug commands" serial.log '^\[sh\] debug commands'
check "chars prints the glyph grid" serial.log '^\[sh\] 0123456789:;<=>\?$'
check "help run3 says it is a debug command" serial.log '^\[sh\]   \(a debug command\)$'
../build.sh >/dev/null

if [ "$ok" -eq 1 ]; then
  echo "PASS: help, help (command), Tab completion and the debug build flag"
  exit 0
fi
echo "FAIL: see above"
exit 1
