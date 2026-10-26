#!/usr/bin/env bash
#
# verify_coff_inside.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Moonshot compiles, links and runs a program on its own. The kernel seeds
# coff.elf, smed.elf and hello.c0, and the shell runs
#
#   start coff.elf --elf hello.c0 hello.s
#   start smed.elf --base 0x80000000 hello.s hello.elf
#   start hello.elf
#
# The first two must exit 0 and hello.elf must print its line and exit 7.
# Then the same through the shell's execute, from a folder of its own, so
# coff reads and writes there and hello.elf ends up beside its source with
# no hello.s left over. Last, execute on a source with an error has to stop
# at coff, say so, and start nothing.
# Then hello.s is printed over serial and compared byte for byte with what
# coff1 on the host makes of the same hello.c0, so the compiler inside
# Moonshot is shown to be the same compiler, not merely one that works.

set -u
cd "$(dirname "$0")/.."

./build.sh || exit 1

rm -f disk.img serial.log
dd if=/dev/zero of=disk.img bs=512 count=20480 2>/dev/null

mkdir -p out && cd out

isodir=isoroot
rm -rf "$isodir"
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1

sockfile=coff_inside.sock
qemu_pid=0
cleanup() { [ "$qemu_pid" -ne 0 ] && kill "$qemu_pid" 2>/dev/null; wait 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
sleep 3

# Each command waits for one more "[syscall] exit code" line than before, so
# a slow host only makes the test slower.
python3 - "$sockfile" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.3)
def keys(text):
    for c in text:
        name = {" ": "spc", "\n": "ret", ".": "dot", "-": "minus", "/": "slash",
                "(": "shift-9", ")": "shift-0", "{": "shift-bracket_left",
                "}": "shift-bracket_right", ";": "semicolon"}.get(c, c)
        s.send(("sendkey %s\n" % name).encode())
        time.sleep(0.05)
def exits():
    return open("serial.log", "rb").read().count(b"[syscall] exit code=")
def run(cmd, n=1):
    before = exits()
    keys(cmd + "\n")
    deadline = time.time() + 60
    while exits() < before + n and time.time() < deadline:
        time.sleep(0.2)
    time.sleep(0.5)
keys("root\n"); time.sleep(1)
keys("\n"); time.sleep(1.2)
run("start coff.elf --elf hello.c0 hello.s")
run("start smed.elf --base 0x80000000 hello.s hello.elf")
run("start hello.elf")
keys("echo --file hello.s\n"); time.sleep(2)
keys("make proj\n"); time.sleep(0.5)
keys("copy hello.c0 proj/hello.c0\n"); time.sleep(0.5)
keys("change proj\n"); time.sleep(0.5)
run("execute hello.c0", 3)
keys("echo listing\n"); time.sleep(0.5)
keys("list\n"); time.sleep(0.5)
keys("echo end\n"); time.sleep(0.5)
keys("write bad.c0 int main() { return nope; }\n"); time.sleep(0.5)
run("execute bad.c0")
keys("list\n"); time.sleep(1)
s.close()
EOF

ok=1
codes=$(grep -ao '\[syscall\] exit code=-\?[0-9]*' serial.log | grep -o -- '-\?[0-9]*$' | tr '\n' ' ')
echo "exit codes: $codes(expected 0 0 7 0 0 7 1)"
[ "$codes" = "0 0 7 0 0 7 1 " ] || ok=0
listing=$(sed -n '/^\[sh\] listing$/,/^\[sh\] end$/p' serial.log)
if echo "$listing" | grep -q 'hello\.elf' && ! echo "$listing" | grep -q 'hello\.s '; then
  echo "ok    execute left hello.elf in proj and removed hello.s"
else
  echo "FAIL  proj after execute holds:"; echo "$listing"; ok=0
fi
if grep -aq "^\[sh\] execute: coff could not compile bad.c0$" serial.log \
   && grep -aq "undeclared variable 'nope'" serial.log \
   && ! grep -aq 'bad\.elf' serial.log; then
  echo "ok    execute stopped at coff's error for bad.c0"
else
  echo "FAIL  execute did not stop cleanly at bad.c0's error"; ok=0
fi
if grep -aq '^hello from a program built on moonshot$' serial.log; then
  echo "ok    hello.elf printed its line"
else
  echo "FAIL  hello.elf did not print its line"; ok=0
fi

# The hello.s Moonshot wrote, as many bytes after its "[echo] " line as the
# host's coff1 makes of the same hello.c0, plus the newline echo ends with,
# so a file one byte short cannot pass with echo's newline standing in for
# its last one.
awk -F'"' '/^int jakel_hello_source\(\)/ {go=1; next} go && /^";/ {exit} go' ../kernel/files/jakel.c0 \
  | sed 's/^    return "//; s/\\"/"/g; s/\\\\/\\/g' >hello_host.c0
../../c0-coff/coff1 --elf hello_host.c0 host_hello.s
# The kernel's "tick N" lines can land in the middle of the dump, so they
# are taken out first.
python3 - "$(wc -c <host_hello.s)" <<'EOF' >inside_hello.s
import re, sys
log = open("serial.log", "rb").read()
i = log.find(b"[echo] ")
n = int(sys.argv[1])
seg = re.sub(rb"tick \d+\n", b"", log[i + 7:i + 7 + n + 4096]) if i >= 0 else b""
sys.stdout.buffer.write(seg[:n + 1])
EOF
echo >>host_hello.s
if cmp -s inside_hello.s host_hello.s; then
  echo "ok    hello.s from Moonshot is byte-identical to the host's ($(( $(wc -c <host_hello.s) - 1 )) bytes)"
else
  echo "FAIL  hello.s from Moonshot differs from the host's"
  diff inside_hello.s host_hello.s | head -10
  ok=0
fi
rm -f inside_hello.s host_hello.s hello_host.c0

if [ "$ok" -eq 1 ]; then
  echo "PASS: Moonshot compiled, linked and ran hello.c0 with its own coff and smed"
  exit 0
fi
grep -aE '^\[(syscall|elf|sh)\]|^smed:|^coff' serial.log | tail -20
echo "FAIL: compiling on Moonshot"
exit 1
