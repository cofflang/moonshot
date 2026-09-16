#!/usr/bin/env bash
#
# test_repl.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Proves the c0 REPL evaluates expressions correctly.
# Sends `eval` commands via QEMU monitor sendkey and checks the serial log.
set -u
cd "$(dirname "$0")"

cleanup() { rm -f repl_test.sock; }
trap cleanup EXIT

./build.sh || exit 1
if [ ! -f disk.img ]; then
  dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null
fi

isodir=isoroot
rm -rf "$isodir"
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1

rm -f serial.log repl_test.sock
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:repl_test.sock,server,nowait &

QEMU_PID=$!
sleep 4

sendkey() {
  python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('repl_test.sock')
time.sleep(0.3)
for c in '$1':
    name = {
        ' ': 'spc', '\n': 'ret', '/': 'slash', '.': 'dot', '-': 'minus',
        '+': 'shift-equal', '(': 'shift-9', ')': 'shift-0',
        '=': 'equal', '!': 'shift-1', '_': 'shift-minus',
        '<': 'shift-comma', '>': 'shift-dot', '*': 'shift-8',
        ';': 'semicolon', '{': 'shift-bracket_left', '}': 'shift-bracket_right',
        'A': 'shift-a', 'B': 'shift-b', 'C': 'shift-c', 'D': 'shift-d',
        'E': 'shift-e', 'F': 'shift-f', 'H': 'shift-h', 'I': 'shift-i',
        'L': 'shift-l', 'N': 'shift-n', 'P': 'shift-p', 'R': 'shift-r',
        'S': 'shift-s', 'T': 'shift-t', 'U': 'shift-u', 'V': 'shift-v',
        'W': 'shift-w', 'X': 'shift-x', 'Y': 'shift-y',
    }.get(c, c)
    s.send(f'sendkey {name}\n'.encode())
    time.sleep(0.03)
time.sleep(0.5)
" 2>/dev/null
}

# Byte offset into serial.log taken just before the current command was sent,
# so a check only ever looks at output that command produced.
#
# check() used to grep the whole cumulative log, which means a test could pass
# on a value some EARLIER test had printed -- `check '\[repl] 5'` is satisfied
# by any of the several earlier expressions that also produce 5. Nothing was
# known to be passing spuriously, but the suite could not have told us.
mark=0
serial_size() { if [ -f serial.log ]; then wc -c < serial.log; else echo 0; fi; }

# The serial log has several writers going at once -- the keyboard isr, the
# scheduler, the timer -- and the repl prints its prefix, its value and its
# newline as three separate calls. So a correct `[jit] -8` genuinely arrives as
# `[jit] key scancode 156` followed by `-8` on the next line, and a plain grep
# for '\[jit] -8' misses it.
#
# The kernel could print atomically instead, but only by disabling interrupts
# around every debug print, which is a real cost to pay for a test's
# convenience. Normalising here is the cheaper half of that trade: delete the
# async messages wherever they land, INCLUDING mid-line, drop what that leaves
# empty, then glue a dangling `[repl] `/`[jit] ` prefix back onto the value
# below it.
normalize() {
  python3 -c '
import re, sys
text = sys.stdin.read()

# Each async message is removed together with the newline it printed itself.
# That is the whole trick, and it is why this is not a line-based filter.
#
# serial_print writes a byte at a time, so an interrupt can land between ANY
# two bytes -- not politely between records. A real failure showed the message
# "[jit] unknown variable" arriving as "[jit] unkn" / "own variable", split
# mid-word by an isr message that had inserted itself there and ended with a
# newline. Deleting only the text leaves that stray newline behind and the
# record stays broken in two; deleting the message AND its newline restores
# the byte stream exactly as the writer intended it.
#
# This is safe for a message that did occupy its own line, because the line
# before it ended with its own newline, which is not the one being removed.
for pattern in (
    r"key scancode \d+\n?",
    r"\[sched\] -> task \d+ \(counter=\d+\)\n?",
    r"kakel typed: win=\d+ char=\d+(?: row=\d+ col=\d+)?\n?",
    r"tick \d+\n?",
):
    text = re.sub(pattern, "", text)
sys.stdout.write(text)
'
}

# Only the output the current command produced, normalised.
window() { tail -c "+$((mark + 1))" serial.log 2>/dev/null | normalize; }

# What the guest ACTUALLY received, rebuilt from the kernel's own per-character
# echo. This is the check that would have saved a session: when `-(5 + 3)` came
# back as -6, the natural reading was a compiler bug, and the first thing that
# had to be ruled out was the harness dropping or mis-shifting a keystroke.
# Now the harness answers that question itself, every command, instead of
# leaving it to be reconstructed by hand afterwards.
typed_since() {
  tail -c "+$((mark + 1))" serial.log 2>/dev/null \
    | grep -oE 'kakel typed: win=[0-9]+ char=[0-9]+' \
    | grep -oE 'char=[0-9]+$' | cut -d= -f2 \
    | python3 -c "
import sys
out = ''.join(chr(int(l)) for l in sys.stdin if l.strip())
print(out.replace('\n', ''), end='')
" 2>/dev/null
}

failures=0
last_cmd=""

type_cmd() {
  mark=$(serial_size)
  last_cmd="$1"
  sendkey "$1"
  sendkey "\n"
  sleep 1
}

# Reports a garbled command as a HARNESS problem rather than a wrong value,
# because those need completely different responses and look identical in a
# bare grep failure.
check() {
  local got
  got=$(typed_since)
  if [ -n "$last_cmd" ] && [ "$got" != "$last_cmd" ]; then
    echo "  FAIL: $1 (INPUT GARBLED -- sent '$last_cmd', guest received '$got')"
    failures=$((failures + 1))
    return
  fi
  if window | grep -q "$2"; then
    echo "  OK: $1"
  else
    echo "  FAIL: $1 (missing '$2')"
    echo "        guest received: '$got'"
    echo "        output for this command was:"
    window | sed 's/^/          /'
    failures=$((failures + 1))
  fi
}

# Log in as root (raket's boot-time login gate) before any shell command can
# reach shell_run -- root has no password set at boot, so an empty password
# line is what logs in. See raket.c0.
type_cmd "root"
type_cmd ""

# Arithmetic
type_cmd "eval 2 + 3 * 4"
check "2+3*4 = 14" '\[repl] 14'

type_cmd "eval 10 - 3 - 2"
check "10-3-2 = 5" '\[repl] 5'

type_cmd "eval 20 / 4"
check "20/4 = 5" '\[repl] 5'

type_cmd "eval -5 + 10"
check "-5+10 = 5" '\[repl] 5'

# Hex literal
type_cmd "eval 0x10 + 1"
check "0x10+1 = 17" '\[repl] 17'

# Comparisons (use simple ones that do not need complex shift combos)
type_cmd "eval 3 == 3"
check "3==3 = 1" '\[repl] 1'

# Variables
type_cmd "eval x = 42"
check "x=42 assigns" '\[repl] 42'

type_cmd "eval x + 1"
check "x+1 = 43" '\[repl] 43'

type_cmd "eval x * 2"
check "x*2 = 84" '\[repl] 84'

# print()
type_cmd "eval print(99)"
check "print(99)" '\[repl] 99'

# Division by zero
type_cmd "eval 1 / 0"
check "1/0 error" 'division by zero'

# --- REPL v2: control flow ---

# if/else: then-branch
type_cmd "eval if (1) { print(77); }"
check "if(1) print(77)" '\[repl] 77'

# if/else: else-branch
type_cmd "eval if (0) { print(1); } else { print(88); }"
check "if(0) else print(88)" '\[repl] 88'

# while loop
type_cmd "eval c = 3; while (c > 0) { c = c - 1; } print(c)"
check "while countdown" '\[repl] 0'

# --- REPL v3: for loops ---

# for loop counting up (short var names, no spaces for faster sendkey)
type_cmd "eval for(a=0;a<3;a=a+1){print(a);}"
check "for 0..2 print" '\[repl] 0'
check "for 0..2 print" '\[repl] 1'
check "for 0..2 print" '\[repl] 2'

# for condition-only (empty init)
type_cmd "eval b=2;for(;b>0;b=b-1){print(b);}"
check "for condition-only" '\[repl] 2'
check "for condition-only" '\[repl] 1'

# --- REPL v4: break / continue ---

# break in while
type_cmd "eval while(1){print(1);break;}print(2)"
check "break in while (1)" '\[repl] 1'
check "break in while (2)" '\[repl] 2'

# continue in while
type_cmd "eval c=0;while(c<3){c=c+1;if(c==2){continue;}print(c);}"
check "continue in while (1)" '\[repl] 1'
check "continue in while (3)" '\[repl] 3'

# break in for
type_cmd "eval for(a=0;a<5;a=a+1){if(a==2){break;}print(a);}"
check "break in for (0)" '\[repl] 0'
check "break in for (1)" '\[repl] 1'

# continue in for
type_cmd "eval for(a=0;a<4;a=a+1){if(a==1){continue;}print(a);}"
check "continue in for (0)" '\[repl] 0'
check "continue in for (2)" '\[repl] 2'
check "continue in for (3)" '\[repl] 3'

# break outside loop (error)
type_cmd "eval break;"
check "break outside loop" 'break outside loop'

# --- JIT compile-and-execute ---

# Arithmetic
type_cmd "eval -c 2 + 3 * 4"
check "jit 2+3*4 = 14" '\[jit] 14'

type_cmd "eval -c 10 - 3 - 2"
check "jit 10-3-2 = 5" '\[jit] 5'

type_cmd "eval -c 20 / 4"
check "jit 20/4 = 5" '\[jit] 5'

type_cmd "eval -c -5 + 10"
check "jit -5+10 = 5" '\[jit] 5'

# Hex literal
type_cmd "eval -c 0x10 + 1"
check "jit 0x10+1 = 17" '\[jit] 17'

# Comparisons
type_cmd "eval -c 3 == 3"
check "jit 3==3 = 1" '\[jit] 1'

type_cmd "eval -c 3 == 4"
check "jit 3==4 = 0" '\[jit] 0'

type_cmd "eval -c 5 < 10"
check "jit 5<10 = 1" '\[jit] 1'

type_cmd "eval -c 5 > 10"
check "jit 5>10 = 0" '\[jit] 0'

# Multiplication
type_cmd "eval -c 6 * 7"
check "jit 6*7 = 42" '\[jit] 42'

# Nested arithmetic
type_cmd "eval -c (1 + 2) * (3 + 4)"
check "jit (1+2)*(3+4) = 21" '\[jit] 21'

# Unary minus
type_cmd "eval -c -(5 + 3)"
check "jit -(5+3) = -8" '\[jit] -8'

# Division by zero (compile-time error)
type_cmd "eval -c 1 / 0"
check "jit 1/0 error" 'division by zero'

# JIT variables — set via interpreter, use via JIT.
type_cmd "eval x = 99"
sleep 1
type_cmd "eval -c x + 1"
check "jit var x+1 = 100" '\[jit] 100'

type_cmd "eval y = 7"
sleep 1
type_cmd "eval -c y * y"
check "jit var y*y = 49" '\[jit] 49'

type_cmd "eval z = 10"
sleep 1
type_cmd "eval -c z - 3"
check "jit var z-3 = 7" '\[jit] 7'

# JIT with multiple variables in one expression.
type_cmd "eval -c x + y + z"
check "jit var x+y+z = 116" '\[jit] 116'

# JIT undefined variable should error.
type_cmd "eval -c undefined_var + 1"
check "jit undefined var" 'unknown variable'

# JIT print() — calls into jit_print_helper via JIT_PRINT_ADDR.
# Extra sleep: JIT compilation + execution needs time before the check.
type_cmd "eval -c print(77)"
sleep 2
check "jit print 77" '\[jit] 77'

# --- run from file ---

# Write a file and run it through the interpreter.
# The unique values (9947+53=10000) were chosen so a cumulative grep could not
# match some earlier eval's output. check() is windowed to the current command
# now, so that is belt and braces rather than the only defence -- kept because
# a distinctive value still makes a failure easier to read.
type_cmd "write runtest.c0 9947 + 53"
sleep 3
type_cmd "run runtest.c0"
sleep 3
check "run file 9947+53" '\[repl] 10000'

# Run the seeded demo.c0 (created in jakel_init on first boot).
# Uses distinctive values (777, 888, 999) to avoid false positives.
type_cmd "list"
sleep 1
type_cmd "echo --file demo.c0"
sleep 2
type_cmd "run demo.c0"
sleep 2
check "demo.c0 print(777)" '\[repl] 777'
# n=888 is not auto-printed: repl_eval only prints the LAST statement
# in a multi-statement block, and print(n+999) is last. The value is
# verified indirectly — print(n+999) → 1887 proves n was set correctly.
check "demo.c0 print(n+999)" '\[repl] 1887'

# Shutdown
echo "quit" | python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('repl_test.sock')
time.sleep(1)
s.send(b'quit\n')
time.sleep(1)
" 2>/dev/null
wait $QEMU_PID 2>/dev/null || true

if [ "$failures" -eq 0 ]; then
  echo "PASS: c0 REPL — all expression evaluations correct"
  exit 0
else
  echo "FAIL: $failures REPL expression(s) wrong"
  echo "--- serial.log ---"
  cat serial.log
  exit 1
fi
