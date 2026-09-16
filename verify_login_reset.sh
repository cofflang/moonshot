#!/usr/bin/env bash
#
# verify_login_reset.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Proves that closing the last window does NOT hand back an already
# authenticated shell.
#
# Window ids are reused: closing the last window frees its slot and
# immediately allocates a replacement, which gets the same id back. Every
# per-session array -- raket's authed flag, skalman's uid and cwd -- is
# indexed by window id, so the replacement used to inherit `authed = 1` from
# the session that had just been closed, walking straight past the login gate.
#
# The check is behavioural rather than a flag readback: after the close, the
# script types `root` and Enter. If the window is at a login prompt, raket
# logs a username line for a SECOND session. If it were already authenticated,
# `root` would instead reach the shell as a command and come back unknown.

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
  echo "FAIL: grub-mkrescue did not produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

sockfile=verify_login_reset.sock
rm -f serial.log "$sockfile"
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:"$sockfile",server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; rm -f "$sockfile"; }
trap cleanup EXIT

sleep 2

python3 - "$sockfile" <<'EOF'
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
    keymap = {".": "dot", " ": "spc", "-": "minus"}
    typ([keymap.get(c, c) for c in s])

# First login, on the boot window.
word("root"); typ(["ret"]); time.sleep(0.5)
typ(["ret"]); time.sleep(1.0)

# Prove we really are in a shell now: run a command.
word("tasks"); typ(["ret"]); time.sleep(1.0)

# Close the last window. kakel replaces it with a fresh one, reusing the id.
word("close"); typ(["ret"]); time.sleep(1.5)

# Type `root` into the replacement. At a login prompt this becomes raket's
# username line; in an already-authenticated shell it would be a bad command.
word("root"); typ(["ret"]); time.sleep(0.8)
typ(["ret"]); time.sleep(1.0)

sock.close()
EOF

sleep 1

ok=1

echo "--- raket session lines ---"
grep '\[raket\] session' serial.log || true

logins=$(grep -c "\[raket\] session .* username='root'" serial.log || true)
echo "login prompts answered with root: $logins"
if [ "$logins" -lt 2 ]; then
  echo "FAIL: the replacement window did not ask for a login --"
  echo "  closing the last window handed back an authenticated shell"
  ok=0
fi

# The negative half: `root` must never have reached the shell as a command.
if grep -q 'unknown command: root' serial.log; then
  echo "FAIL: 'root' reached the shell as a command, so the window was already authenticated"
  ok=0
fi

panics=$(grep -c 'PANIC' serial.log || true)
dfs=$(grep -c 'double fault' serial.log || true)
echo "panics: $panics, double faults: $dfs"
if [ "$panics" -ne 0 ] || [ "$dfs" -ne 0 ]; then
  echo "FAIL: crash during the run"
  ok=0
fi

echo
if [ "$ok" -eq 1 ]; then
  echo "PASS: closing the last window returns a fresh, unauthenticated session --"
  echo "  the replacement asked for a login instead of inheriting the closed one"
  exit 0
fi
echo "FAIL: login state survived a window close"
exit 1
