#!/usr/bin/env bash
#
# verify_execute_spaces.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# A source path with spaces reaches coff as one argument when execute
# constructs its internal command line.
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

rm -f serial.log execute_spaces.sock execute-command.log
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:execute_spaces.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f execute_spaces.sock; }
trap cleanup EXIT

python3 - <<'PY' || exit 1
import re
import socket
import time

deadline = time.monotonic() + 15
s = None
while time.monotonic() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect("execute_spaces.sock")
        break
    except OSError:
        if s:
            s.close()
        s = None
        time.sleep(0.1)
if s is None:
    raise SystemExit("FAIL: QEMU monitor did not become available")

def monitor_prompt():
    data = b""
    deadline = time.monotonic() + 5
    while b"(qemu) " not in data and time.monotonic() < deadline:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    if b"(qemu) " not in data:
        raise SystemExit("FAIL: QEMU monitor did not answer")
    return data

monitor_prompt()

def read_serial():
    try:
        with open("serial.log", "rb") as log:
            return log.read()
    except FileNotFoundError:
        return b""

def wait_serial(marker, timeout=30, start=0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pos = read_serial().find(marker, start)
        if pos >= 0:
            return pos + len(marker)
        time.sleep(0.1)
    raise SystemExit("FAIL: timed out waiting for serial marker %r" % marker)

def send_key(key):
    s.sendall(("sendkey %s\n" % key).encode())
    monitor_prompt()
    time.sleep(0.15)

def type_line(text):
    keys = {" ": "spc", ".": "dot"}
    for c in text:
        send_key(keys.get(c, c))
    send_key("ret")

wait_serial(b"[sched] -> task 4")
time.sleep(4)
login_start = len(read_serial())
type_line('root')
type_line('')
login_end = wait_serial(b"[raket] screen login username='root' uid=0 ok=1\n",
                        start=login_start)
wait_serial(b"[sh] prompt\n", start=login_end)
copy_start = len(read_serial())
type_line('copy hello.c0 space case.c0')
copy_end = wait_serial(b"[sh] prompt\n", 15, start=copy_start)
if b"[sh] copy:" in read_serial()[copy_start:copy_end]:
    raise SystemExit("FAIL: could not copy the source to the path containing spaces")

execute_start = len(read_serial())
try:
    type_line('execute space case.c0')
    wait_serial(b"[sh] started task ", start=execute_start)
    wait_serial(b"[sh] prompt\n", start=execute_start)
    wait_serial(b"[syscall] exit code=7\n", start=execute_start)
finally:
    command_log = read_serial()[execute_start:]
    with open("execute-command.log", "wb") as log:
        log.write(command_log)

started = re.search(rb"^\[sh\] started task [0-9]+$", command_log, re.MULTILINE)
exited = re.search(rb"^\[syscall\] exit code=7$", command_log, re.MULTILINE)
if not started or not exited:
    raise SystemExit("FAIL: execute did not compile and start the source path containing spaces")
print("PASS: execute compiled and started a source file whose path contains spaces")
print(started.group().decode())
print(exited.group().decode())
s.close()
PY
