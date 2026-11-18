#!/usr/bin/env bash
#
# verify_elf_corpus.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Starts every malformed ELF in the corpus tests/elf/31_elf_corpus.c0 writes
# (test/m01.elf to test/m49.elf) from the shell and checks that each one is
# refused cleanly and that the machine still works afterwards.
#
# A clean refusal is the refusal the case expects (the shell's own for a file
# that is not an ELF or is too large, the loader's "[elf] invalid ELF64
# image" for the rest), no "[elf] loaded" line, no exit code 77 (every case
# carries code that exits with 77, so an image that should have been refused
# and ran says so), no panic, and the task that tried it exited. A "runs"
# case is a valid layout and must load and exit with 77. Afterwards the
# shell still answers, a valid program (et01) still runs to its expected
# exit code, and the free physical page count is back where it was before the
# corpus (see LEAK below).
#
# The default run also starts test/broken.elf (tests/elf/26_broken_elf.c0
# writes it) 20 times and checks that the free page count is the same
# before and after, so a refused start gives back the address space made for
# it (E-04). And it starts every "invalid" case a second time through
# SYS_SPAWN, from a program, the way a program starts another (the
# generator's spawn mode).
#
#   tests/verify_elf_corpus.sh            the passing cases, one boot
#   tests/verify_elf_corpus.sh m17 m23    the named cases, one boot
#   tests/verify_elf_corpus.sh --known    each known failure in a boot of
#                                         its own, reporting what it does,
#                                         and the page count check (LEAK)
#   tests/verify_elf_corpus.sh --each m17 m28
#                                         each named case in a boot of its
#                                         own, reporting what it does and the
#                                         free page count around it, which
#                                         must not change by a page, so one
#                                         case that stops the machine or
#                                         takes every page cannot hide another
#   tests/verify_elf_corpus.sh --run3     a debug kernel, the shell's run3
#                                         (which loads a program into the
#                                         shell's own task) on broken.elf
#                                         and a few cases, then the page
#                                         count and the shell
#
# KNOWN cases record open findings and stay out of the default run.
# A KNOWN case satisfying the acceptance checks is a classification error
# reported by --known. Accepted cases belong in PASSING.
set -u
cd "$(dirname "$0")/.."

# id  expected refusal  finding  what is wrong
PASSING="
m01 notelf -     not an ELF, the shell refuses it before the loader
m02 invalid F-02 the four magic bytes and nothing else
m03 invalid F-02 a valid image cut one byte short of its ELF header
m04 invalid -    ELFCLASS32
m05 invalid -    big-endian
m06 invalid -    ET_DYN
m07 invalid -    EM_386
m08 invalid -    identification version 0
m09 invalid -    ELF header size 52
m10 invalid F-02 no program headers
m11 invalid E-03 program header stride 0, one header
m12 invalid E-03 program header stride 0, 4096 headers
m13 invalid F-02 program header stride 32
m14 invalid F-02 program header table a megabyte past the end
m15 invalid F-02 negative program header offset
m16 invalid F-02 one program header more than the file holds
m17 invalid F-01 segment at 0x7F000000, below the user range
m18 invalid F-01 segment over the kernel identity map, 0x100000
m19 invalid F-01 segment at -4096
m20 invalid F-01 segment in the kernel half, 0xFFFF800000000000
m21 invalid F-01 segment filling the last canonical page, 0x7FFFFFFFF000
m22 invalid F-01 non-canonical segment, 0x800000000000
m23 invalid E-03 the same program header twice
m24 invalid E-03 two segments with distinct bytes in one page
m25 invalid E-03 two segments overlapping in one page of two
m26 size    -    one byte over ELF_MAX_BYTES
m27 invalid E-04 a 256MB segment, more memory than there is
m28 invalid E-01 second segment p_memsz 0x7FFFFFFFFFFFF000
m29 invalid E-01 second segment p_memsz -4096
m30 invalid E-01 second segment whose page rounding wraps
m31 invalid F-02 p_filesz larger than p_memsz
m32 invalid F-02 p_offset a megabyte past the end of the file
m33 invalid F-02 p_filesz one byte past the end of the file
m34 invalid F-02 p_offset -64
m35 invalid E-02 entry 0x0001000000000000, not canonical
m36 invalid E-02 entry 0x0000800000000000, not canonical
m37 invalid E-02 entry 0xFFFF800000000000, kernel half
m38 invalid E-02 entry 0x90000000, in no segment
m39 invalid E-02 entry in a segment that is not executable
m40 invalid E-02 entry one byte past the end of its segment
m41 invalid -    e_version 0
m42 invalid F-02 bss segment with p_offset a megabyte past the end
m43 invalid F-01 segment too high for the stack and heap above it
m44 invalid F-01 segment under 4GB, in the framebuffer's shared tables
m45 runs    -    valid, a bss-only second segment
m46 runs    -    valid, a second segment of no memory at address 0
m47 runs    -    valid, program header stride 64
m48 invalid F-01 segment whose heap would reach the framebuffer's tables
m49 invalid W^X   one segment both writable and executable
"

# LEAK labels an allowed page loss. When it is empty, any loss fails.
LEAK=""

# Open findings are excluded from the default run. The fourth column is
# a metadata tag for the finding.
# id  expected refusal  finding  tag  what is wrong
KNOWN="
"

# Free pages a run may lose and still pass. A task slot used for the first
# time takes its stack from jenna and keeps it in the stack pool, which is
# the one cost a start leaves behind.
SLACK=8

mode=suite
picked=()
if [ "${1:-}" = "--known" ]; then mode=known
elif [ "${1:-}" = "--each" ]; then mode=each; shift; picked=("$@")
elif [ "${1:-}" = "--run3" ]; then mode=run3
elif [ $# -gt 0 ]; then mode=picked; picked=("$@"); fi

./tools/gen_elf_tests.sh >/dev/null || exit 1
if [ "$mode" = run3 ]; then
  MOONSHOT_DEBUG=1 ./build.sh >/dev/null || { echo "FAIL: build.sh"; exit 1; }
else
  ./build.sh >/dev/null || { echo "FAIL: build.sh"; exit 1; }
fi

gen=$(awk '$2=="31_elf_corpus.c0"{print $1}' tests/elf/manifest.txt)
good=$(awk '$2=="01_control_flow.c0"{print $1}' tests/elf/manifest.txt)
good_expect=$(awk '$2=="01_control_flow.c0"{print $3}' tests/elf/manifest.txt)
broken=$(awk '$2=="26_broken_elf.c0"{print $1}' tests/elf/manifest.txt)
[ -n "$gen" ] && [ -n "$good" ] && [ -n "$broken" ] || { echo "FAIL: corpus generator, et01 or 26_broken_elf missing from the manifest"; exit 1; }

mkdir -p out && cd out
isodir=isoroot_corpus
rm -rf "$isodir" corpus.iso
mkdir -p "$isodir/boot/grub"
cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o corpus.iso "$isodir" >grub-mkrescue.log 2>&1
rm -rf "$isodir"
[ -f corpus.iso ] || { echo "FAIL: grub-mkrescue did not produce corpus.iso"; cat grub-mkrescue.log; exit 1; }

cleanup() {
  rm -f corpus.sock corpus.img corpus.iso
  # --run3 leaves a debug kernel in build/, the next test gets an ordinary one.
  if [ "$mode" = run3 ]; then (cd .. && ./build.sh >/dev/null); fi
}
trap cleanup EXIT

python3 - "$mode" "$gen" "$good" "$good_expect" "$PASSING" "$KNOWN" "$LEAK" "$broken" "$SLACK" "${picked[@]}" <<'PY'
import os, re, socket, subprocess, sys, time

mode, gen, good, good_expect, passing, known, leak, broken, slack = sys.argv[1:10]
picked = sys.argv[10:]
leak = leak.split()
slack = int(slack)

def table(text, known_flag):
    rows = {}
    for ln in text.strip().splitlines():
        if known_flag:
            cid, kind, finding, fix, what = ln.split(None, 4)
        else:
            (cid, kind, finding, what), fix = ln.split(None, 3), "-"
        rows[cid] = (kind, finding, what, known_flag, fix)
    return rows
cases = table(passing, False)
cases.update(table(known, True))
for c in picked:
    if c not in cases:
        print("unknown case %s" % c); sys.exit(2)

KEYS = {".": "dot", " ": "spc", "-": "minus", "/": "slash"}
unfinished_freed = 0

def boot(run):
    """Boots once, logs in, writes the corpus, then calls run(line)."""
    for f in ("corpus.sock", "corpus.img", "corpus-serial.log"):
        if os.path.exists(f): os.remove(f)
    with open("corpus.img", "wb") as f: f.truncate(512 * 20480)
    q = subprocess.Popen(["qemu-system-x86_64", "-cdrom", "corpus.iso",
        "-serial", "file:corpus-serial.log", "-display", "none", "-no-reboot", "-m", "128",
        "-drive", "file=corpus.img,format=raw,if=ide,index=0,media=disk",
        "-monitor", "unix:corpus.sock,server,nowait"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(3)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect("corpus.sock")
        sock.setblocking(False)
        time.sleep(0.3)
        # A case that stops the machine ends QEMU, and the cases after it
        # are reported as never reached rather than ending the test here.
        gone = [False]
        def send(cmd):
            try:
                sock.sendall((cmd + "\n").encode())
            except OSError:
                gone[0] = True
                return
            time.sleep(0.06)
            try: sock.recv(65536)
            except (BlockingIOError, OSError): pass
        def line(s, wait):
            if gone[0] or q.poll() is not None: return
            for ch in s:
                send("sendkey " + KEYS.get(ch, ch))
                time.sleep(0.05)
            send("sendkey ret")
            time.sleep(wait)
        line("root", 0.5)
        line("", 1.2)
        line("echo gen", 0.4)
        line("start test/%s.elf write" % gen, 5.0)
        line("echo wb", 0.4)
        line("start test/%s.elf" % broken, 1.5)
        run(line)
        sock.close()
        time.sleep(0.5)
    finally:
        q.kill()
        q.wait()
    with open("corpus-serial.log", "rb") as f:
        log = f.read().decode("latin-1")
    # Console, timer and reaper diagnostics can interleave with result lines.
    # Count reclaimed unfinished address spaces before stripping diagnostics.
    global unfinished_freed
    unfinished_freed = len(re.findall(r"\[sched\] freed unfinished address space of task \d+, \d+ pages\n", log))
    return re.sub(r"(key scancode \d+|tick \d+|kakel typed: [^\n]*"
                  r"|\[sched\] freed unfinished address space of task \d+, \d+ pages)\n", "", log)

MARK = re.compile(r"^\[sh\] (gen|wb|m\d\d|p\d|b20|spawn|r3|good|alive|corpus done)$", re.M)

def segments(log):
    """The serial output after each marker, up to the next one."""
    seg = {}
    ms = list(MARK.finditer(log))
    for i, m in enumerate(ms):
        end = ms[i + 1].start() if i + 1 < len(ms) else len(log)
        seg[m.group(1)] = log[m.end():end]
    return seg

REFUSAL = {
    "invalid": "[elf] invalid ELF64 image",
    "notelf": "[sh] start: not a program",
    "size": "[sh] start: file empty or too large",
}

def verdict(cid, s):
    """(clean, what happened) for one case's piece of serial."""
    kind = cases[cid][0]
    if s is None:
        return False, "never reached, the machine stopped earlier"
    seen = []
    refused = kind != "runs" and REFUSAL[kind] in s
    if kind == "runs" and "[elf] invalid ELF64 image" in s: seen.append("refused")
    if refused: seen.append("refused")
    if "[elf] loaded" in s: seen.append("loaded")
    if "exit code=77" in s: seen.append("ran its code to exit 77")
    m = re.search(r"stopped, exception vector=(\d+)", s)
    if m: seen.append("killed in ring 3 by exception %s" % m.group(1))
    panic = "PANIC" in s or "halting" in s
    if panic: seen.append("kernel panic")
    for other in re.findall(r"^\[elf\] (.*)$", s, re.M):
        if not other.startswith(("loaded", "invalid", "windowed", "no window")):
            seen.append(other)
    exited = re.search(r"^\[sched\] task \d+ (exited|stopped)", s, re.M) is not None
    if kind == "invalid" and refused and not exited: seen.append("task did not exit")
    clean = refused and "[elf] loaded" not in s and "exit code=77" not in s and not panic
    if kind == "invalid": clean = clean and exited
    if kind == "runs":
        clean = ("[elf] loaded" in s and "exit code=77" in s and not panic
                 and "[elf] invalid ELF64 image" not in s)
    if not seen: seen.append("no refusal and no load seen")
    return clean, ", ".join(seen)

def exit_code(s):
    m = re.search(r"exit code=(-?\d+)", s or "")
    return int(m.group(1)) if m else None

def last_exit_code(s):
    m = re.findall(r"exit code=(-?\d+)", s or "")
    return int(m[-1]) if m else None

BROKEN_STARTS = 20
SPAWN_BATCH = 20

def corpus(ids):
    """One boot. test/broken.elf BROKEN_STARTS times between two free page
    counts, then the cases in ids, then the invalid ones among them again
    through SYS_SPAWN, then a last count."""
    spawn_ids = [c for c in ids if cases[c][0] == "invalid"]
    def run(line):
        line("echo p0", 0.4)
        line("start test/%s.elf pages" % gen, 1.5)
        line("echo p1", 0.4)
        line("start test/%s.elf pages" % gen, 1.5)
        line("echo b20", 0.4)
        for _ in range(BROKEN_STARTS):
            line("start test/broken.elf", 1.0)
        line("echo p3", 0.4)
        line("start test/%s.elf pages" % gen, 1.5)
        # SYS_SPAWN before the shell's starts. m27 takes every free page and
        # leaves none at the top of jenna's range, so from then on a task
        # gets its stack only from one an ended task gave back.
        if spawn_ids:
            # The shell takes lines of up to 128 characters.
            line("echo spawn", 0.4)
            for b in range(0, len(spawn_ids), SPAWN_BATCH):
                batch = spawn_ids[b:b + SPAWN_BATCH]
                nums = " ".join(str(int(c[1:])) for c in batch)
                line("start test/%s.elf spawn %s" % (gen, nums), 4.0 + 0.6 * len(batch))
        for cid in ids:
            line("echo " + cid, 0.4)
            line("start test/%s.elf" % cid, 4.0 if cid == "m27" else 1.5)
        line("echo p2", 0.4)
        line("start test/%s.elf pages" % gen, 1.5)
        line("echo good", 0.4)
        line("start test/%s.elf" % good, 1.5)
        line("echo corpus done", 0.6)
    log = boot(run)
    return log, segments(log), spawn_ids

passing_ids = [c for c in cases if not cases[c][3]]
known_ids = [c for c in cases if cases[c][3]]

if mode == "each":
    failed = 0
    for cid in picked:
        def run(line, cid=cid):
            line("echo p0", 0.4)
            line("start test/%s.elf pages" % gen, 1.5)
            line("echo p1", 0.4)
            line("start test/%s.elf pages" % gen, 1.5)
            line("echo " + cid, 0.4)
            line("start test/%s.elf" % cid, 4.0 if cid == "m27" else 2.5)
            line("echo p2", 0.4)
            line("start test/%s.elf pages" % gen, 1.5)
            line("echo alive", 0.6)
        log = boot(run)
        seg = segments(log)
        clean, what = verdict(cid, seg.get(cid))
        alive = "alive" in seg
        p1, p2 = exit_code(seg.get("p1")), exit_code(seg.get("p2"))
        # No SLACK here. Every task slot a case uses has run a program
        # earlier in the boot, so one refused start that loses a page shows.
        kept = p1 is not None and p2 is not None and p2 == p1
        pages = "free pages %s before, %s after" % (p1, p2)
        if p1 is not None and p2 is not None: pages += ", %+d" % (p2 - p1)
        good_run = clean and alive and kept and "PANIC" not in log
        if not good_run: failed += 1
        print("  %s %s %-5s %-50s %s; %s; shell %s" % ("ok  " if good_run else "FAIL", cid,
              cases[cid][1], cases[cid][2][:50], what, pages, "answered" if alive else "did not answer"))
    print("PASS: %d cases, each in a boot of its own" % len(picked) if not failed
          else "FAIL: %d of %d cases" % (failed, len(picked)))
    sys.exit(0 if not failed else 1)

if mode == "known":
    still = 0
    for cid in known_ids:
        def run(line, cid=cid):
            line("echo p0", 0.4)
            line("start test/%s.elf pages" % gen, 1.5)
            line("echo p1", 0.4)
            line("start test/%s.elf pages" % gen, 1.5)
            line("echo " + cid, 0.4)
            line("start test/%s.elf" % cid, 4.0 if cid == "m27" else 2.5)
            line("echo p2", 0.4)
            line("start test/%s.elf pages" % gen, 1.5)
            line("echo alive", 0.6)
        log = boot(run)
        seg = segments(log)
        clean, what = verdict(cid, seg.get(cid))
        alive = "alive" in seg
        p1, p2 = exit_code(seg.get("p1")), exit_code(seg.get("p2"))
        kept = p1 is not None and p2 is not None and p2 >= p1 - slack
        if not kept:
            what += ", free pages %s before and %s after" % (p1, p2)
        state = "now refused cleanly, move it to PASSING" if clean and alive and kept else "still open"
        if state == "still open": still += 1
        kind, finding, desc, _, fix = cases[cid]
        print("  %s %-5s %-7s %-50s %s; shell %s; %s" % (cid, finding, fix, desc[:50], what,
              "answered" if alive else "did not answer", state))
    total = len(known_ids)
    if leak:
        total += 1
        log, seg, _ = corpus(passing_ids)
        p1, p2 = exit_code(seg.get("p1")), exit_code(seg.get("p2"))
        held = p1 is not None and p2 is not None and p2 >= p1 - slack
        if not held: still += 1
        print("  pages %-5s %-7s the PASSING cases took the free page count from %s to %s; %s" % (
              leak[0], leak[1], p1, p2, "now holds, empty LEAK" if held else "still open"))
    print("%d of %d known failures still open" % (still, total))
    sys.exit(0)

def pages_check(what, before, after):
    """Prints the free page count over one part of the run, False when it
    lost more than SLACK pages and no LEAK excuses it, or gained more, which
    is a page given back twice."""
    if before is None or after is None:
        print("FAIL: no free page count %s (%s, %s)" % (what, before, after))
        return False
    print("  free pages %s %d, after %d, %+d" % (what, before, after, after - before))
    if after > before + slack:
        print("FAIL: gained %d pages %s, a page went back twice" % (after - before, what))
        return False
    if after >= before - slack:
        return True
    if leak:
        print("  known failure %s, fixed by %s, lost %d pages %s" % (leak[0], leak[1], before - after, what))
        return True
    print("FAIL: lost %d pages %s" % (before - after, what))
    return False

if mode == "run3":
    # run3 loads a program into the shell's own task. A refused one returns
    # to the shell, and the address space made for it must still be freed,
    # by the reaper, while the shell goes on running.
    R3_CASES = ["m17", "m28", "m35", "m39", "m42", "m43", "m44"]
    R3_BROKEN = 10
    def run(line):
        line("echo p0", 0.4)
        line("start test/%s.elf pages" % gen, 1.5)
        line("echo p1", 0.4)
        line("start test/%s.elf pages" % gen, 1.5)
        line("echo r3", 0.4)
        for _ in range(R3_BROKEN):
            line("run3 test/broken.elf", 1.0)
        for cid in R3_CASES:
            line("run3 test/%s.elf" % cid, 1.5)
        line("echo p2", 0.4)
        line("start test/%s.elf pages" % gen, 1.5)
        line("echo alive", 0.6)
    log = boot(run)
    seg = segments(log)
    s = seg.get("r3", "")
    ok = True
    want = R3_BROKEN + len(R3_CASES)
    refused = s.count("[elf] invalid ELF64 image")
    print("  run3 %d starts, %d refused, %d unfinished address spaces freed in the whole boot" % (
          want, refused, unfinished_freed))
    if refused != want:
        print("FAIL: %d of %d run3 starts refused" % (refused, want)); ok = False
    if "[elf] loaded" in s or "exit code=77" in s:
        print("FAIL: a run3 case loaded"); ok = False
    ok = pages_check("over the run3 starts", exit_code(seg.get("p1")), exit_code(seg.get("p2"))) and ok
    if "alive" not in seg:
        print("FAIL: the shell did not answer after run3"); ok = False
    if "PANIC" in log:
        print("FAIL: kernel panic"); ok = False
    print("PASS: every run3 start refused, the shell answers and keeps its pages" if ok else "FAIL")
    sys.exit(0 if ok else 1)

ok = True
run_ids = picked if picked else passing_ids
log, seg, spawn_ids = corpus(run_ids)

written = exit_code(seg.get("gen"))
if written != 49:
    print("FAIL: the generator wrote %s of 49 files" % written); ok = False
if exit_code(seg.get("wb")) != 1:
    print("FAIL: test/broken.elf was not written"); ok = False
b = seg.get("b20", "")
b_refused = b.count("[elf] invalid ELF64 image")
print("  test/broken.elf started %d times, refused %d times" % (BROKEN_STARTS, b_refused))
if b_refused != BROKEN_STARTS or "[elf] loaded" in b:
    print("FAIL: test/broken.elf was not refused every time"); ok = False
ok = pages_check("over the broken.elf starts", exit_code(seg.get("p1")), exit_code(seg.get("p3"))) and ok
for cid in run_ids:
    clean, what = verdict(cid, seg.get(cid))
    kind, finding, desc, is_known, fix = cases[cid]
    tag = "known failure, " if is_known else ""
    print("  %s %s %-5s %-50s %s%s" % ("ok  " if clean else "FAIL", cid, finding, desc[:50], tag, what))
    if not clean: ok = False
if spawn_ids:
    s = seg.get("spawn", "")
    s_refused = s.count("[elf] invalid ELF64 image")
    codes = [int(c) for c in re.findall(r"exit code=(-?\d+)", s)]
    batches = (len(spawn_ids) + SPAWN_BATCH - 1) // SPAWN_BATCH
    print("  SYS_SPAWN %d cases, %d refused, exit codes %s" % (len(spawn_ids), s_refused, codes))
    if s_refused != len(spawn_ids) or len(codes) != batches or any(codes):
        print("FAIL: not every case was refused through SYS_SPAWN"); ok = False
ok = pages_check("over the whole corpus", exit_code(seg.get("p1")), exit_code(seg.get("p2"))) and ok
print("  the reaper freed %d unfinished address spaces" % unfinished_freed)
if exit_code(seg.get("good")) != int(good_expect):
    print("FAIL: %s did not exit with %s after the corpus" % (good, good_expect)); ok = False
if "corpus done" not in seg:
    print("FAIL: the shell did not answer after the corpus"); ok = False
if "PANIC" in log:
    print("FAIL: kernel panic"); ok = False
print("PASS: every case refused cleanly, and the machine works after them" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
