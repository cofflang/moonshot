#!/usr/bin/env bash
#
# verify_jit_name_runtime.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Trace the executed diagnostic loads separately from their serial output.
set -eu
cd "$(dirname "$0")/.."

./build.sh
mkdir -p out
cd out
rm -rf jit-isoroot
mkdir -p jit-isoroot/boot/grub
cp ../build/moonshot.elf jit-isoroot/boot/moonshot.elf
cp ../kernel/core/grub_test.cfg jit-isoroot/boot/grub/grub.cfg
grub-mkrescue -o jit-name.iso jit-isoroot >jit-grub.log 2>&1

rm -f jit-serial.log jit-monitor.sock jit-gdb.sock jit-ready jit-events.jsonl
qemu-system-x86_64 -cdrom jit-name.iso \
  -serial file:jit-serial.log -display none -no-reboot -m 128 -S \
  -monitor unix:jit-monitor.sock,server,nowait \
  -gdb unix:jit-gdb.sock,server=on,wait=off &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; rm -f jit-monitor.sock jit-gdb.sock; }
trap cleanup EXIT

python3 - <<'PY'
import json
from pathlib import Path
import re
import socket
import struct
import subprocess
import time

elf = Path("../build/moonshot.elf").read_bytes()
symbols = {name: int(addr, 16) for addr, name in
           (line.split() for line in Path("../build/moonshot.map").read_text().splitlines())}
phoff = struct.unpack_from("<Q", elf, 32)[0]
phsize, phcount = struct.unpack_from("<HH", elf, 54)

def image(addr, size):
    for i in range(phcount):
        kind, flags, offset, base, physical, length, memsize, align = struct.unpack_from(
            "<IIQQQQQQ", elf, phoff + i * phsize)
        if kind == 1 and base <= addr and addr + size <= base + length:
            return elf[offset + addr - base:offset + addr - base + size]
    raise SystemExit("FAIL: diagnostic address is outside the ELF load segments")

begin, end = symbols["jit_compile_node"], symbols["jit_compile_and_run"]
code = image(begin, end - begin)
sites = []
for pos in range(len(code) - 8):
    if code[pos:pos + 4] != bytes.fromhex("48 89 c7 e8"):
        continue
    target = begin + pos + 8 + struct.unpack_from("<i", code, pos + 4)[0]
    if target != symbols["serial_putc"]:
        continue
    for opcode, width in [("48 0f b6 80 00 00 00 00", 1),
                          ("48 8b 80 00 00 00 00", 8)]:
        raw = bytes.fromhex(opcode)
        if code[pos - len(raw):pos] == raw:
            sites.append({"pc": begin + pos - len(raw), "size": len(raw),
                          "width": width, "opcode": raw.hex()})
if len(sites) != 2:
    raise SystemExit("FAIL: expected exactly two diagnostic load/serial_putc sites")
for site, branch in zip(sites, ["unknown", "known"]):
    site["branch"] = branch
Path("jit-sites.json").write_text(json.dumps(sites, indent=2) + "\n")

Path("jit-trace.gdb").write_text('''set pagination off
set confirm off
set architecture i386:x86-64
target remote ./jit-gdb.sock
python
import gdb, json
from pathlib import Path
events = open("jit-events.jsonl", "w")
class LoadTrace(gdb.Breakpoint):
    def __init__(self, site, phase):
        self.site, self.phase = site, phase
        pc = site["pc"] + (site["size"] if phase == "after" else 0)
        super().__init__("*0x%x" % pc, type=gdb.BP_HARDWARE_BREAKPOINT, internal=True)
    def stop(self):
        site = self.site
        event = {"branch": site["branch"], "phase": self.phase,
                 "pc": int(gdb.parse_and_eval("$pc")),
                 "rax": int(gdb.parse_and_eval("$rax"))}
        if self.phase == "before":
            raw = bytes(gdb.selected_inferior().read_memory(event["pc"], site["size"]))
            event["opcode"] = raw.hex()
            event["width"] = {bytes.fromhex("48 0f b6 80 00 00 00 00"): 1,
                              bytes.fromhex("48 8b 80 00 00 00 00"): 8}.get(raw, 0)
            event["byte"] = int.from_bytes(gdb.selected_inferior().read_memory(event["rax"], 1), "little")
            event["instruction"] = gdb.execute("x/i $pc", to_string=True).strip()
        events.write(json.dumps(event) + "\\n")
        events.flush()
        return False
for site in json.loads(Path("jit-sites.json").read_text()):
    LoadTrace(site, "before")
    LoadTrace(site, "after")
Path("jit-ready").write_text("ready\\n")
end
continue
''')

def wait_for(predicate, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise SystemExit("FAIL: timed out waiting for " + description)

def serial():
    return Path("jit-serial.log").read_bytes() if Path("jit-serial.log").exists() else b""

def normalized(data):
    for pattern in (rb"key scancode \d+\n?",
                    rb"\[sched\] -> task \d+ \(counter=\d+\)\n?",
                    rb"kakel typed: win=\d+ char=\d+(?: row=\d+ col=\d+)?\n?",
                    rb"tick \d+\n?"):
        data = re.sub(pattern, b"", data)
    return data

def wait_serial(marker, start=0):
    return wait_for(lambda: marker in normalized(serial()[start:]), repr(marker))

wait_for(lambda: Path("jit-gdb.sock").exists(), "GDB socket")
gdb_log = open("jit-gdb.log", "wb")
debugger = subprocess.Popen(["gdb", "--batch", "-nx", "-x", "jit-trace.gdb"],
                            stdout=gdb_log, stderr=subprocess.STDOUT)
monitor = None
try:
    wait_for(lambda: Path("jit-ready").exists(), "armed runtime trace")
    monitor = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    monitor.settimeout(5)
    monitor.connect("jit-monitor.sock")

    def monitor_prompt():
        data = b""
        while b"(qemu) " not in data:
            chunk = monitor.recv(4096)
            if not chunk:
                raise SystemExit("FAIL: QEMU monitor closed")
            data += chunk

    monitor_prompt()

    def type_line(text):
        keys = {" ": "spc", "_": "shift-minus", "=": "equal",
                "+": "shift-equal", "-": "minus"}
        for char in text + "\n":
            monitor.sendall(("sendkey %s\n" % keys.get(char, "ret" if char == "\n" else char)).encode())
            monitor_prompt()
            time.sleep(0.15)

    def command(text):
        start = len(serial())
        type_line(text)
        wait_serial(b"[sh] prompt\n", start)
        data = serial()[start:]
        typed = bytes(int(x) for x in re.findall(rb"kakel typed: win=\d+ char=(\d+)", data))
        if typed != (text + "\n").encode():
            raise SystemExit("FAIL: guest input differs from command %r, got %r" % (text, typed))
        return normalized(data)

    wait_for(lambda: b"[sched] -> task 4" in serial(), "shell task")
    time.sleep(4)
    start = len(serial())
    type_line("root")
    type_line("")
    wait_serial(b"[raket] screen login username='root' uid=0 ok=1\n", start)
    wait_serial(b"[sh] prompt\n", start)
    assigned = command("eval edge_name = 37")
    known = command("eval -c edge_name + 5")
    unknown = command("eval -c absent_name + 5")
    Path("jit-known.log").write_bytes(known)
    Path("jit-unknown.log").write_bytes(unknown)
    if b"[repl] 37\n" not in assigned or b"[jit] var edge_name = 37\n" not in known \
            or b"[jit] 42\n" not in known \
            or b"[jit] unknown variable 'absent_name'\n" not in unknown:
        raise SystemExit("FAIL: complete diagnostic names or expression behavior differ")
    print("PASS: exact known and unknown diagnostic names with adjacent source bytes")

    events = [json.loads(line) for line in Path("jit-events.jsonl").read_text().splitlines()]
    errors = []
    for branch, name in [("known", b"edge_name"), ("unknown", b"absent_name")]:
        selected = [event for event in events if event["branch"] == branch]
        before = [event for event in selected if event["phase"] == "before"]
        after = [event for event in selected if event["phase"] == "after"]
        if len(before) != len(name) or len(after) != len(name):
            errors.append("%s trace did not execute every name byte" % branch)
            continue
        for i, (load, retired) in enumerate(zip(before, after)):
            if load["width"] != 1:
                errors.append("%s diagnostic load at 0x%x has width %d" %
                              (branch, load["pc"], load["width"]))
            if load["rax"] != before[0]["rax"] + i or load["byte"] != name[i] \
                    or retired["rax"] & 255 != name[i] \
                    or retired["pc"] != load["pc"] + len(bytes.fromhex(load["opcode"])):
                errors.append("%s trace address/value/retirement mismatch" % branch)
        print("TRACE: %s bytes=%d widths=%s pc=0x%x address=0x%x" %
              (branch, len(before), sorted(set(x["width"] for x in before)),
               before[0]["pc"], before[0]["rax"]))
    if errors:
        raise SystemExit("FAIL: " + "; ".join(dict.fromkeys(errors)))
    print("PASS: both actual diagnostic load sites executed byte-wide reads")
finally:
    if monitor:
        monitor.close()
    if debugger.poll() is None:
        debugger.terminate()
        try:
            debugger.wait(timeout=5)
        except subprocess.TimeoutExpired:
            debugger.kill()
            debugger.wait()
    gdb_log.close()
PY
