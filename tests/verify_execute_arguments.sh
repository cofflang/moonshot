#!/usr/bin/env bash
#
# verify_execute_arguments.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Builds and runs only in an independent sibling snapshot. Evidence stays
# in EXECUTE_EVIDENCE_DIR. Automatic evidence is retained only on failure.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${EXECUTE_EVIDENCE_DIR:-}" ]; then
    EXECUTE_EVIDENCE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/moonshot-execute-arguments.XXXXXXXX")
    export EXECUTE_EVIDENCE_DIR
    cleanup_evidence() {
        result=$?
        if [ "$result" -eq 0 ]; then
            rm -rf -- "$EXECUTE_EVIDENCE_DIR"
        else
            printf 'FAIL evidence retained at %s\n' "$EXECUTE_EVIDENCE_DIR" >&2
        fi
    }
    trap cleanup_evidence EXIT
fi
python3 - "$PWD" <<'PY'
import hashlib
import atexit
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback

source = Path(sys.argv[1])
evidence = Path(os.environ["EXECUTE_EVIDENCE_DIR"]).resolve()
evidence.mkdir(parents=True, exist_ok=True)
print("evidence:", evidence, flush=True)
def failure(kind, value, tb):
    (evidence / "failure.txt").write_text("".join(traceback.format_exception(kind, value, tb)))
    sys.__excepthook__(kind, value, tb)
sys.excepthook = failure
base = evidence / "snapshot"
if base.exists():
    raise SystemExit("FAIL: evidence directory already has a snapshot")
excluded = {".git", "release", "isoroot", "out"}
def ignore(directory, names):
    return [n for n in names if n in excluded or
            n.endswith((".iso", ".img", ".log", ".wav", ".sock"))]
for name in ("moonshot", "c0-coff", "gnista", "utsikt"):
    src = source.parent / name
    if src.is_dir():
        shutil.copytree(src, base / name, ignore=ignore, copy_function=shutil.copy2)
root = base / "moonshot"
out = root / "out"
out.mkdir()
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
tracked = ("kernel/shell/skalman.c0", "kernel/core/syscall.c0",
           "build.sh", "tests/verify_execute_spaces.sh",
           "tests/verify_execute_arguments.sh")
identities = {p: digest(root / p) for p in tracked}
originals = {p: (root / p).read_bytes() for p in tracked}
(evidence / "source-hashes.txt").write_text(
    "".join(f"{h}  {p}\n" for p, h in identities.items()))
def restore():
    for p, data in originals.items():
        (root / p).write_bytes(data)
    (evidence / "restoration.txt").write_text(
        "".join(f"{digest(root / p)}  {p}\n" for p in tracked))
    assert all(digest(root / p) == h for p, h in identities.items())
atexit.register(restore)
full = os.environ.get("EXECUTE_PHASE", "full") != "minimal"
mutation = os.environ.get("EXECUTE_MUTATION", "none")
def cstr(text):
    return json.dumps(text)
helper_cases = [
    ("empty-roundtrip", "", [b""]),
    ("space-roundtrip", "   ", [b"   "]),
    ("plain-roundtrip", "hello.c0", [b"hello.c0"]),
    ("spaced-roundtrip", "space case.c0", [b"space case.c0"]),
    ("quote-roundtrip", 'a"b', [b'a"b']),
    ("slash-roundtrip", "a\\b", [b"a\\b"]),
    ("repeated-trailing-roundtrip", 'a\\\\b\\', [b'a\\\\b\\']),
    ("combined-roundtrip", 'a \\\\"b\\', [b'a \\\\"b\\']),
]
parser_cases = [
    ("empty-input", "", []),
    ("spaces-input", "   ", []),
    ("empty-word", '""', [b""]),
    ("two-empty-words", '"" ""', [b"", b""]),
    ("unclosed-quote", '"abc', [b"abc"]),
    ("unclosed-trailing-slash", '"abc\\', [b"abc\\"]),
    ("adjacent-quotes", '"a""b"', [b"a", b"b"]),
    ("ordinary-literals", '"a b" q\\\\r', [b'"a', b'b"', b'q\\\\r']),
]
if full:
    fixture = r'''
void ea_bytes(int s) {
    int i = 0;
    while (load8(s + i) != 0) {
        serial_print_int(load8(s + i));
        serial_print(",");
        i += 1;
    }
    return;
}
void ea_dump(int tag, int cwd, int args) {
    serial_print("[ea] ");
    serial_print(tag);
    serial_print("|");
    serial_print_int(cwd);
    serial_print("|");
    int count = 0;
    if (args) { count = load64(args); }
    serial_print_int(count);
    serial_print("|");
    int p = args + 8;
    int i = 0;
    for (i = 0; i < count; i += 1) {
        ea_bytes(p);
        serial_print("|");
        p += jakel_str_len(p) + 1;
    }
    serial_print("\n");
    return;
}
void ea_clone(int srcdir, int src, int dstdir, int dst) {
    int f = jakel_open(srcdir, src);
    if (f < 0) { serial_print("[ea-fixture] missing clone source\n"); return; }
    int n = load64(jakel_size_base + f * 8);
    int buf = kmalloc(n);
    if (!buf) { serial_print("[ea-fixture] allocation failure\n"); return; }
    jakel_read(JAKEL_SYSTEM, f, 0, buf, n);
    jakel_seed_file(dstdir, dst, buf, n);
    kfree(buf);
    return;
}
void ea_stat(int dir, int name) {
    serial_print("[ea-stat] ");
    serial_print(name);
    serial_print("|");
    int f = jakel_open(dir, name);
    if (f < 0) { serial_print("absent\n"); return; }
    int n = load64(jakel_size_base + f * 8);
    int buf = kmalloc(n);
    jakel_read(JAKEL_SYSTEM, f, 0, buf, n);
    int sum = 0;
    int i = 0;
    for (i = 0; i < n; i += 1) { sum = (sum * 31 + load8(buf + i)) & 2147483647; }
    kfree(buf);
    serial_print_int(n);
    serial_print("|");
    serial_print_int(sum);
    serial_print("\n");
    return;
}
void ea_helpers() {
    int q = 0;
    int b = 0;
'''
    for tag, text, expected in helper_cases:
        fixture += (f"    q = sk_quote({cstr(text)});\n"
                    "    b = sk_args_block_quoted(q);\n"
                    f"    ea_dump({cstr(tag)}, 0, b);\n"
                    "    if (b) { kfree(b); }\n    kfree(q);\n")
    for tag, text, expected in parser_cases:
        call = "sk_args_block" if tag == "ordinary-literals" else "sk_args_block_quoted"
        fixture += (f"    b = {call}({cstr(text)});\n"
                    f"    ea_dump({cstr(tag)}, 0, b);\n"
                    "    if (b) { kfree(b); }\n")
    fixture += "    return;\n}\nvoid ea_seed() {\n"
    ring_source = r'''
int main() {
    if (argc() == 2) {
        int flags = 0;
        int ok = 1;
        for (flags = 0; flags < 4; flags += 1) {
            int line = "/args.elf \"a b\" q\\\\r";
            if (flags >= 2) { line = "args.elf \"a b\" q\\\\r"; }
            int tid = syscall(20, line, flags, 0, 0, 0);
            int code = syscall(29, tid, 0, 0, 0, 0);
            if (code != 62) { ok = 0; }
        }
        if (ok) { print("EA_SYS_SPAWN_OK\n"); }
        else { print("EA_SYS_SPAWN_FAILED\n"); }
        return 63;
    }
    print("EA_RING|");
    int i = 0;
    for (i = 0; i < argc(); i += 1) { print(argv(i)); print("|"); }
    print("\n");
    if (argc() == 4) {
        return syscall(27, 62, 0, 0, 0, 0);
    }
    return syscall(27, 61, 0, 0, 0, 0);
}
'''
    seeds = {
        "old.c0": 'int main() { print("EA_STALE_EXECUTED\\n"); return 73; }\n',
        "cbad.c0": "int main() { return nope; }\n",
        "lbad.c0": "extern int ea_missing_symbol;\nint main() { return ea_missing_symbol; }\n",
        "args.c0": ring_source,
        "fault.c0": "int main() { return load64(0); }\n",
    }
    for name, text in seeds.items():
        fixture += f"    jakel_seed_page(0, {cstr(name)}, {cstr(text)});\n"
    fixture += '''    serial_print("[ea-fixture] sources seeded\\n");
    return;
}
void ea_failseed() {
    int code = sk_run_wait_quoted(JAKEL_SYSTEM, 0, 0, "/coff.elf --elf hello.c0 good.s");
    serial_print("[ea-fixture] stale assembly compiler status=");
    serial_print_int(code);
    serial_print("\\n");
    code = sk_run_wait_quoted(JAKEL_SYSTEM, 0, 0, "/coff.elf --elf fault.c0 fault.s");
    serial_print("[ea-fixture] fault compiler status=");
    serial_print_int(code);
    serial_print("\\n");
    code = sk_run_wait_quoted(JAKEL_SYSTEM, 0, 0, "/smed.elf --base 0x80000000 fault.s fault.elf");
    serial_print("[ea-fixture] fault linker status=");
    serial_print_int(code);
    serial_print("\\n");
'''
    for name in ("cbad", "lbad", "miss", "crash", "lmiss", "lcrash"):
        fixture += f'    ea_clone(0, "old.elf", 0, "{name}.elf");\n'
    fixture += '''    ea_clone(0, "good.s", 0, "cbad.s");
    ea_clone(0, "hello.c0", 0, "miss.c0");
    ea_clone(0, "hello.c0", 0, "crash.c0");
    ea_clone(0, "hello.c0", 0, "lmiss.c0");
    ea_clone(0, "hello.c0", 0, "lcrash.c0");
    ea_clone(0, "coff.elf", 0, "saved.elf");
    ea_clone(0, "smed.elf", 0, "saved-smed.elf");
    ea_stat(0, "old.elf");
    ea_stat(0, "cbad.elf");
    ea_stat(0, "lbad.elf");
    return;
}
void ea_inspect(int dir) {
'''
    for name in ("hello.elf", "hello.s", "space case.elf", "space case.s",
                 'q"u.elf', 'q"u.s', "b\\\\r.elf", "b\\\\r.s",
                 "old.elf", "cbad.elf", "lbad.elf", "cbad.s", "lbad.s",
                 "miss.elf", "crash.elf", "lmiss.elf", "lcrash.elf",
                 "lmiss.s", "lcrash.s"):
        fixture += f"    ea_stat(dir, {cstr(name)});\n"
    fixture += "    return;\n}\n"
    skpath = root / "kernel/shell/skalman.c0"
    sk = skpath.read_text()
    dispatch = '''
    if (str_eq(cmd, "eahelpers") == 1) { ea_helpers(); return; }
    if (str_eq(cmd, "easeed") == 1) { ea_seed(); return; }
    if (str_eq(cmd, "eafailseed") == 1) { ea_failseed(); return; }
    if (str_eq(cmd, "eainspect") == 1) {
        int dir = sk_cwd(f);
        ea_inspect(dir);
        return;
    }
    if (str_eq(cmd, "easyscall") == 1) {
        int dir = sk_cwd(f);
        int code = sk_run_wait(sk_uid(f), dir, sk_cwd_stamp(f), "args.elf spawn");
        serial_print("[ea-fixture] spawn parent status=");
        serial_print_int(code);
        serial_print("\\n");
        return;
    }
    if (str_eq(cmd, "eamissing") == 1) { jakel_remove(JAKEL_SYSTEM, jakel_open(0, "coff.elf")); return; }
    if (str_eq(cmd, "earestore") == 1) { ea_clone(0, "saved.elf", 0, "coff.elf"); return; }
    if (str_eq(cmd, "eacrash") == 1) { ea_clone(0, "fault.elf", 0, "coff.elf"); return; }
    if (str_eq(cmd, "ealmissing") == 1) { jakel_remove(JAKEL_SYSTEM, jakel_open(0, "smed.elf")); return; }
    if (str_eq(cmd, "ealrestore") == 1) { ea_clone(0, "saved-smed.elf", 0, "smed.elf"); return; }
    if (str_eq(cmd, "ealcrash") == 1) { ea_clone(0, "fault.elf", 0, "smed.elf"); return; }
'''
    needle = '    int xr = str_starts(cmd, "execute ");'
    assert sk.count(needle) == 1
    sk = sk.replace(needle, dispatch + needle)
    needle = "void sk_execute(int f, int src) {"
    sk = sk.replace(needle, needle + '''
    serial_print("[ea-input] ");
    ea_bytes(src);
    serial_print("\\n");
''')
    needle = """    int tid = spawn_system_quoted(uid, cwd, cwd_stamp, line, 0);
    if (tid == 0 - 8) { return 0 - 1008; }
    return sk_wait_task(tid);"""
    assert sk.count(needle) == 1, "sk_run_wait_quoted changed, update this hook"
    sk = sk.replace(needle, """    int tid = spawn_system_quoted(uid, cwd, cwd_stamp, line, 0);
    if (tid == 0 - 8) { return 0 - 1008; }
    int result = sk_wait_task(tid);
    serial_print("[ea-wait] tid=");
    serial_print_int(tid);
    serial_print(" how=");
    int how = 0;
    if (tid >= 0 && task_end_base) { how = load64(task_end_base + tid * 8); }
    serial_print_int(how);
    serial_print(" result=");
    serial_print_int(result);
    serial_print("\\n");
    return result;""")
    if mutation == "quote":
        sk = sk.replace("store8(out, 34);", "store8(out, 32);")
        sk = sk.replace("store8(out + p, 34);", "store8(out + p, 32);")
    elif mutation in ("quote-escape", "backslash-escape"):
        old = "if (c == 34 || c == 92) {"
        assert sk.count(old) == 1
        sk = sk.replace(old, "if (c == " +
                        ("92" if mutation == "quote-escape" else "34") + ") {")
    elif mutation == "decode-escape":
        old = "if (quoted == 1 && c == 92 && i + 1 < n"
        assert sk.count(old) == 1
        sk = sk.replace(old, "if (quoted == 1 && c == 0 && i + 1 < n")
    elif mutation == "mode0":
        old = "return sk_args_block_mode(s, 0);"
        assert sk.count(old) == 1
        sk = sk.replace(old, "return sk_args_block_mode(s, 1);")
    elif mutation in ("compiler-gate", "linker-gate"):
        start = sk.index("void sk_execute(")
        end = sk.index("// --- password infrastructure", start)
        body = sk[start:end]
        assert body.count("if (code != 0) {") == 2
        pos = body.index("if (code != 0) {")
        if mutation == "linker-gate":
            pos = body.index("if (code != 0) {", pos + 1)
        body = body[:pos] + body[pos:].replace("if (code != 0) {", "if (0) {", 1)
        sk = sk[:start] + body + sk[end:]
    else:
        assert mutation == "none", "unknown mutation"
    skpath.write_text(sk + fixture)
    syspath = root / "kernel/core/syscall.c0"
    sy = syspath.read_text()
    needle = "    int name = args + 8;    // the first word, NUL-terminated"
    assert sy.count(needle) == 1
    sy = sy.replace(needle, '    ea_dump("spawn", cwd, args);\n' + needle)
    syspath.write_text(sy)
    (evidence / "fixture-skalman.c0").write_text(sk + fixture)
    (evidence / "fixture-syscall.c0").write_text(sy)
    (evidence / "fixture-hashes.txt").write_text(
        f"{digest(skpath)}  kernel/shell/skalman.c0\n"
        f"{digest(syspath)}  kernel/core/syscall.c0\n")
    (evidence / "mutation.txt").write_text(mutation + "\n")

def command(args, log, cwd=root):
    with (evidence / log).open("wb") as stream:
        subprocess.run(args, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                       check=True)

command(["bash", "./build.sh"], "build.log")
iso = out / "isoroot"
(iso / "boot/grub").mkdir(parents=True)
shutil.copy2(root / "build/moonshot.elf", iso / "boot/moonshot.elf")
shutil.copy2(root / "kernel/core/grub_test.cfg", iso / "boot/grub/grub.cfg")
command(["grub-mkrescue", "-o", str(out / "moonshot.iso"), str(iso)], "iso.log")
(evidence / "artifact-hashes.txt").write_text(
    "".join(f"{digest(p)}  {p.relative_to(base)}\n" for p in
            (root / "build/moonshot.elf", out / "moonshot.iso",
             base / "c0-coff/coff1", base / "c0-coff/smed")))

serial = evidence / "serial.log"
socket_dir = Path(tempfile.mkdtemp(prefix="execute-socket."))
sockpath = socket_dir / "monitor.sock"
qlog = (evidence / "qemu.log").open("wb")
qemu = None
launching = False
pending_signal = 0
s = None
def read():
    return serial.read_bytes() if serial.exists() else b""
def clean(data):
    return re.sub(rb"\[sched\][^\n]*\n|tick \d+\n|key scancode \d+\n", b"", data)
def wait(marker, start=0, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = read()
        pos = data.find(marker, start)
        if pos >= 0:
            return pos + len(marker)
        if marker in clean(data[start:]):
            return len(data)
        if marker == b"[sh] prompt\n" and b"sh] prompt\n" in clean(data[start:]):
            return len(data)
        if qemu.poll() is not None:
            raise AssertionError("QEMU exited while waiting for " + repr(marker))
        time.sleep(.1)
    raise AssertionError("timeout waiting for " + repr(marker))
def monitor():
    data = b""
    deadline = time.monotonic() + 5
    previous_timeout = s.gettimeout()
    try:
        while b"(qemu) " not in data:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("QEMU monitor response timed out")
            s.settimeout(remaining)
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                raise AssertionError("QEMU monitor response timed out") from None
            if not chunk:
                raise AssertionError("QEMU monitor closed connection")
            data += chunk
        return data
    finally:
        s.settimeout(previous_timeout)
def key(name):
    s.sendall(("sendkey " + name + "\n").encode())
    monitor()
    time.sleep(.15)
def line(text):
    mapping = {" ": "spc", ".": "dot", "/": "slash", "-": "minus",
               '"': "shift-apostrophe", "\\": "backslash"}
    for c in text:
        key(mapping.get(c, c))
    key("ret")
counter = 0
def run(text, markers=(), absent=()):
    global counter
    counter += 1
    start = len(read())
    try:
        line(text)
        end = wait(b"[sh] prompt\n", start)
        for marker in markers:
            if marker.startswith(b"[syscall] exit"):
                end = max(end, wait(marker, start, timeout=15))
            else:
                assert marker in clean(read()[start:end]), (text, "missing", marker)
        time.sleep(.5)
        end = len(read())
        data = clean(read()[start:end])
        for marker in absent:
            assert marker not in data, (text, "unexpected", marker)
        print("COMPLETE:", text, flush=True)
        with (evidence / "commands-completed.txt").open("a") as log:
            log.write(text + "\n")
        return data
    finally:
        (evidence / f"command-{counter:02d}.log").write_bytes(read()[start:])
def records(data, tag="spawn"):
    result = []
    for row in re.findall(rb"^\[ea\] " + tag.encode() + rb"\|([^\n]*)$", data, re.M):
        fields = row.split(b"|")
        cwd, count = map(int, fields[:2])
        args = [bytes(int(v) for v in field.split(b",") if v)
                for field in fields[2:-1]]
        assert len(args) == count, (tag, row)
        result.append((cwd, args))
    return result
def input_bytes(data, src):
    rows = re.findall(rb"^\[ea-input\] ([^\n]*)$", data, re.M)
    assert len(rows) == 1, ("missing keyboard evidence", src)
    assert bytes(int(v) for v in rows[0].split(b",") if v) == src.encode(), (
        "keyboard did not deliver exact source bytes", src, rows)
def pipeline(src, nonroot=False, exit_code=7):
    data = run("execute " + src,
               (f"[syscall] exit code={exit_code}\n".encode(),))
    if not full:
        return data
    input_bytes(data, src)
    stem = src[:-3]
    wanted = [[b"/coff.elf", b"--elf", src.encode(), (stem + ".s").encode()],
              [b"/smed.elf", b"--base", b"0x80000000",
               (stem + ".s").encode(), (stem + ".elf").encode()],
              [(stem + ".elf").encode()]]
    got = records(data)
    assert [args for cwd, args in got] == wanted, ("tool argv mismatch", src, got)
    cwds = [cwd for cwd, args in got]
    assert len(set(cwds)) == 1 and (cwds[0] > 0 if nonroot else cwds[0] == 0), cwds
    assert data.count(b"how=1 result=0\n") == 2, ("tool statuses", src)
    return data
def stats(data):
    return dict(re.findall(rb"^\[ea-stat\] ([^|\n]+)\|([^\n]+)$", data, re.M))
def artifacts(names):
    values = stats(run("eainspect"))
    for stem in names:
        assert values[(stem + ".elf").encode()] != b"absent", ("missing ELF", stem)
        assert values[(stem + ".s").encode()] == b"absent", ("assembly remains", stem)
    return values
def failure_case(name, stage, status):
    data = run("execute " + name + ".c0")
    input_bytes(data, name + ".c0")
    actual = [args[0] for cwd, args in records(data)]
    expected = [b"/coff.elf"] + ([b"/smed.elf"] if stage == "smed" else [])
    assert actual == expected, ("stage gate allowed next spawn", name, actual)
    assert f"[sh] execute: {stage} could not ".encode() in data, ("stage error", name)
    assert b"[sh] started task " not in data, ("final task started", name)
    assert b"EA_STALE_EXECUTED" not in data, ("stale ELF launched", name)
    if status == "nonzero":
        assert re.search(rb"\[ea-wait\] tid=\d+ how=1 result=[1-9]\d*\n", data), data
    elif status == "missing":
        assert b"[ea-wait] tid=-2 how=0 result=-1000\n" in data
    else:
        assert re.search(rb"\[ea-wait\] tid=\d+ how=2 result=-1000\n", data), data
    return data
def terminate(signum, frame):
    global pending_signal
    if launching:
        pending_signal = signum
    else:
        raise SystemExit(128 + signum)
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, terminate)
try:
    launching = True
    qemu = subprocess.Popen(
        ["qemu-system-x86_64", "-cdrom", str(out / "moonshot.iso"),
         "-serial", "file:" + str(serial), "-display", "none", "-no-reboot",
         "-m", "128", "-monitor", "unix:" + str(sockpath) + ",server,nowait"],
        cwd=root, stdout=qlog, stderr=subprocess.STDOUT)
    launching = False
    if pending_signal:
        raise SystemExit(128 + pending_signal)
    (evidence / "qemu-pid.txt").write_text(str(qemu.pid) + "\n")
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(5)
            s.connect(str(sockpath))
            monitor()
            break
        except OSError:
            if s:
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
    pipeline("hello.c0")
    run("copy hello.c0 space case.c0", absent=(b"[sh] copy:",))
    pipeline("space case.c0")
    print("PASS: minimal real execute pipeline", flush=True)
    if full:
        data = run("eahelpers")
        for tag, text, expected in helper_cases + parser_cases:
            assert records(data, tag) == [(0, expected)], (
                "helper roundtrip mismatch", tag, records(data, tag), expected)
        run("easeed", (b"[ea-fixture] sources seeded\n",))
        pipeline("args.c0", exit_code=61)
        run("make proj")
        run("copy args.c0 proj/args.c0", absent=(b"[sh] copy:",))
        run("change proj")
        pipeline("args.c0", nonroot=True, exit_code=61)
        data = run('start args.elf "a b" q\\\\r', (b"[syscall] exit code=62\n",))
        got = records(data)
        assert len(got) == 1 and got[0][0] > 0
        assert got[0][1] == [b"args.elf", b'"a', b'b"', b"q\\\\r"], got
        assert b'EA_RING|args.elf|"a|b"|q\\\\r|\n' in data, data
        data = run("easyscall", (b"EA_SYS_SPAWN_OK\n",
                   b"[ea-fixture] spawn parent status=63\n"),
                   absent=(b"EA_SYS_SPAWN_FAILED",))
        got = records(data)
        assert len(got) == 5, got
        for index, (cwd, args) in enumerate(got[1:]):
            path = b"/args.elf" if index < 2 else b"args.elf"
            assert (cwd == 0 if index < 2 else cwd > 0), got
            assert args == [path, b'"a', b'b"', b"q\\\\r"], got
        assert len(re.findall(rb'^EA_RING\|[^\n]*\n', data, re.M)) == 4, data
        assert data.count(b"[elf] windowed spawn wid=") == 2, data
        assert b"no window available" not in data, data
        run("change /")
        for src in ('q"u.c0', "b\\\\r.c0"):
            run("copy hello.c0 " + src, absent=(b"[sh] copy:",))
            pipeline(src)
        artifacts(["hello", "space case", 'q"u', "b\\\\r"])
        run("copy hello.c0 proj/hello.c0", absent=(b"[sh] copy:",))
        run("copy hello.c0 proj/space case.c0", absent=(b"[sh] copy:",))
        run("change proj")
        pipeline("hello.c0", nonroot=True)
        pipeline("space case.c0", nonroot=True)
        artifacts(["hello", "space case"])
        run("change /")
        pipeline("old.c0", exit_code=73)
        seed = run("eafailseed", (
            b"[ea-fixture] stale assembly compiler status=0\n",
            b"[ea-fixture] fault compiler status=0\n",
            b"[ea-fixture] fault linker status=0\n"))
        stale = stats(seed)[b"old.elf"]
        assert stale != b"absent"
        assert stats(seed)[b"cbad.elf"] == stale
        assert stats(seed)[b"lbad.elf"] == stale
        data = failure_case("cbad", "coff", "nonzero")
        assert b"undeclared variable 'nope'" in data
        after = stats(run("eainspect"))
        assert after[b"cbad.elf"] == stale
        assert after[b"cbad.s"] != b"absent"
        data = failure_case("lbad", "smed", "nonzero")
        assert b"undefined symbol ea_missing_symbol" in data
        after = stats(run("eainspect"))
        assert after[b"lbad.elf"] == stale
        assert after[b"lbad.s"] == b"absent"
        for setup, target, stage, status, restore_tool in (
            ("eamissing", "miss", "coff", "missing", "earestore"),
            ("eacrash", "crash", "coff", "abnormal", "earestore"),
            ("ealmissing", "lmiss", "smed", "missing", "ealrestore"),
            ("ealcrash", "lcrash", "smed", "abnormal", "ealrestore"),
        ):
            run(setup)
            failure_case(target, stage, status)
            run(restore_tool)
            after = stats(run("eainspect"))
            assert after[(target + ".elf").encode()] == stale
            if stage == "smed":
                assert after[(target + ".s").encode()] == b"absent"
        print("PASS: exact helper/tool argv, cwd/artifacts, real failure gates and mode-0 ABI",
              flush=True)
    (evidence / "result.txt").write_text("PASS\n")
finally:
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    if s:
        s.close()
    if qemu is not None:
        qemu.terminate()
        try:
            qemu.wait(timeout=10)
        except subprocess.TimeoutExpired:
            qemu.kill()
            qemu.wait()
    qlog.close()
    shutil.rmtree(socket_dir)
    (evidence / "normalized-serial.log").write_bytes(clean(read()))
    if qemu is not None:
        (evidence / "cleanup.txt").write_text(f"QEMU {qemu.pid} reaped {qemu.returncode}\n")
PY
