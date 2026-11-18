#!/usr/bin/env bash
#
# verify_start_prompt.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# start gives a program a window of its own, and the split that makes room
# for it lays the shell's window out again from the started task. When that
# task gets the CPU first and splits while the shell is still running the
# start command, the shell must still prompt once the command is done.
# The kernel built here forces that order, so the test does not depend on
# where a timer tick happens to land. It builds and runs only in an
# independent sibling snapshot, and keeps its evidence only on failure.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/moonshot-start-prompt.XXXXXXXX")
keep=0
cleanup() {
    if [ "$keep" -eq 0 ]; then rm -rf -- "$work"; else
        rm -rf -- "$work/snapshot"
        printf 'FAIL evidence retained at %s\n' "$work" >&2
    fi
}
trap cleanup EXIT
python3 - "$PWD" "$work" <<'PY' || { keep=1; exit 1; }
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

source = Path(sys.argv[1])
work = Path(sys.argv[2])
base = work / "snapshot"
excluded = {".git", "release", "isoroot", "out", "company"}
def ignore(directory, names):
    return [n for n in names if n in excluded or
            n.endswith((".iso", ".img", ".log", ".wav", ".sock"))]
for name in ("moonshot", "c0-coff", "gnista", "utsikt"):
    src = source.parent / name
    if src.is_dir():
        shutil.copytree(src, base / name, ignore=ignore, copy_function=shutil.copy2)
root = base / "moonshot"

# Puts text into path right after the first line of needle, which must
# occur exactly once.
def patch(path, needle, text):
    p = root / path
    s = p.read_text()
    assert s.count(needle) == 1, (path, "changed, update this hook", needle)
    first = needle[:needle.index("\n") + 1]
    p.write_text(s.replace(needle, first + text + needle[len(first):]))

# The shell, once start has made the task, waits until that task has split
# the screen, and the task then waits half a second, which is long enough
# for the shell to finish the command and prompt. The mark is cleared before
# the spawn, so only a split from this start can end the wait, and the
# marker line shows that the order was forced.
patch("kernel/shell/skalman.c0",
      "        }\n"
      "        int enid = spawn_program(sk_uid(f), cwd, cst, cmd + s3fr);\n",
      "        sp_split = 0;\n")
patch("kernel/shell/skalman.c0",
      "        int enid = spawn_program(sk_uid(f), cwd, cst, cmd + s3fr);\n", '''\
        if (enid >= 0) {
            int sp_t0 = pit_ticks;
            while (!sp_split && pit_ticks < sp_t0 + 1000) { cpu_wait(); }
            if (sp_split) { serial_print("[sp] the task split first\\n"); }
        }
''')
patch("kernel/core/syscall.c0",
      "        else { wid = kakel_split(); }\n"
      "        store64(task_win_base + tid * 8, wid);\n"
      "        if (wid < 0) {\n", '''\
        if (tid != dvala_tid) {
            sp_split = 1;
            int sp_t1 = pit_ticks;
            while (pit_ticks < sp_t1 + 50) { cpu_wait(); }
        }
''')
patch("kernel/core/syscall.c0", "int spawn_rec_base = 0;\n", "int sp_split = 0;\n")

def run(args, log):
    with (work / log).open("wb") as stream:
        subprocess.run(args, cwd=root, stdout=stream, stderr=subprocess.STDOUT, check=True)

run(["bash", "./build.sh"], "build.log")
out = root / "out"
iso = out / "isoroot"
(iso / "boot/grub").mkdir(parents=True)
shutil.copy2(root / "build/moonshot.elf", iso / "boot/moonshot.elf")
shutil.copy2(root / "kernel/core/grub_test.cfg", iso / "boot/grub/grub.cfg")
run(["grub-mkrescue", "-o", str(out / "moonshot.iso"), str(iso)], "iso.log")

serial = work / "serial.log"
sockdir = Path(tempfile.mkdtemp(prefix="start-prompt."))
sockpath = sockdir / "monitor.sock"
qemu = subprocess.Popen(
    ["qemu-system-x86_64", "-cdrom", str(out / "moonshot.iso"),
     "-serial", "file:" + str(serial), "-display", "none", "-no-reboot",
     "-m", "128", "-monitor", "unix:" + str(sockpath) + ",server,nowait"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
s = None
def read():
    return serial.read_bytes() if serial.exists() else b""
def wait(marker, start=0, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pos = read().find(marker, start)
        if pos >= 0:
            return pos + len(marker)
        if qemu.poll() is not None:
            raise AssertionError("QEMU exited while waiting for " + repr(marker))
        time.sleep(.1)
    raise AssertionError("timeout waiting for " + repr(marker))
def monitor():
    data = b""
    while b"(qemu) " not in data:
        chunk = s.recv(4096)
        if not chunk:
            raise AssertionError("QEMU monitor closed connection")
        data += chunk
def line(text):
    mapping = {" ": "spc", ".": "dot", "/": "slash"}
    for c in text + "\n":
        s.sendall(("sendkey " + ("ret" if c == "\n" else mapping.get(c, c)) + "\n").encode())
        monitor()
        time.sleep(.15)
try:
    deadline = time.monotonic() + 15
    while s is None and time.monotonic() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(5)
            s.connect(str(sockpath))
            monitor()
        except OSError:
            s.close()
            s = None
            time.sleep(.1)
    assert s is not None, "monitor unavailable"
    wait(b"[sched] -> task 4")
    time.sleep(4)
    start = len(read())
    line("root")
    line("")
    pos = wait(b"[raket] screen login username='root' uid=0 ok=1\n", start)
    wait(b"[sh] prompt\n", pos)
    start = len(read())
    line("start test/mouse.elf")
    split = wait(b"[sp] the task split first\n", start, 30)
    shown = wait(b"[elf] windowed spawn wid=", split, 30)
    wait(b"[sh] prompt\n", split, 20)
    time.sleep(1)
    after = read()[split:]
    assert after.count(b"[sh] prompt\n") == 1, ("prompts after start", after.count(b"[sh] prompt\n"))
    start = len(read())
    line("tasks")
    wait(b"[sh] prompt\n", start, 20)
    print("PASS: the shell prompts after start when the started task splits the screen first", flush=True)
except BaseException:
    tail = re.sub(rb"tick \d+\n", b"", read())[-3000:]
    sys.stderr.write(tail.decode("latin-1"))
    raise
finally:
    if s:
        s.close()
    qemu.terminate()
    try:
        qemu.wait(timeout=10)
    except subprocess.TimeoutExpired:
        qemu.kill()
        qemu.wait()
    shutil.rmtree(sockdir)
PY
