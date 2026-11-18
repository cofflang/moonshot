#!/usr/bin/env bash
#
# test_page_tables.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# jenna's page-table builders keep a process out of the kernel's tables,
# give back everything a process mapped, and fail cleanly when memory runs
# out.
#
#   1. Every map_page, map_page_user and map_page_user_data call outside
#      jenna.c0 uses the result, so no caller can carry on after a refusal.
#   2. A test boot runs pt_selftest (jenna.c0), and each of its three lines
#      ends in ok. Refusals of addresses below USER_VIRT_BASE, at 2^48, at
#      the ceiling, negative, unaligned and over the kernel's own subtrees,
#      with the kernel's tree unchanged and no U bit in it. A page under PML4
#      slot 1 coming back on pt_free. pt_create returning 0 with jenna run
#      dry, physical page 0 untouched, and a page given back when only the
#      second allocation fails.
#   3. A kernel built with a null read right after those checks stops at
#      the read with the invariant panic line, rather than reading physical
#      page 0 or mapping it. That build is made by changing knekt.c0 for
#      this build only, the way test_no_framebuffer.sh changes boot.s, and
#      the file is put back by a trap.
#   4. A kernel built to run jenna dry after those checks and then touch an
#      unmapped page beside the demand-paging probe stops in
#      page_fault_handler with the invariant panic line, rather than mapping
#      physical page 0 there and returning. It is built the same way as 3.
set -u
cd "$(dirname "$0")/.."
K=$(pwd)/kernel/core

src_rc=0
if ! python3 - <<'PY'
import glob, re, sys
bad = []
for p in sorted(glob.glob('kernel/**/*.c0', recursive=True)):
    if p.endswith('kernel/core/jenna.c0'):
        continue
    for n, line in enumerate(open(p), 1):
        code = line.split('//')[0]
        for m in re.finditer(r'\bmap_page(_user(_data)?)?\(', code):
            before = code[:m.start()].rstrip()
            if not re.search(r'(if \(!|=|&&|\|\||return)$', before):
                bad.append('%s:%d %s' % (p, n, line.strip()))
for b in bad:
    print('FAIL: mapping result ignored at ' + b)
sys.exit(1 if bad else 0)
PY
then
  src_rc=1
fi

./build.sh >/dev/null 2>&1 || { echo "FAIL: build.sh"; exit 1; }

mkdir -p out && cd out

# boot <name> runs build/moonshot.elf on a test boot until `until` appears
# in the serial log or 20 seconds pass, and leaves the log in <name>.log.
boot() {
  local name=$1 until=$2
  local isodir=isoroot-$name
  rm -rf "$isodir" "$name.iso" "$name.log"
  mkdir -p "$isodir/boot/grub"
  cp ../build/moonshot.elf "$isodir/boot/moonshot.elf"
  cp ../kernel/core/grub_test.cfg "$isodir/boot/grub/grub.cfg"
  grub-mkrescue -o "$name.iso" "$isodir" >"grub-mkrescue-$name.log" 2>&1
  if [ ! -f "$name.iso" ]; then
    echo "FAIL: grub-mkrescue did not produce $name.iso"
    return 1
  fi
  qemu-system-x86_64 -cdrom "$name.iso" \
    -serial file:"$name.log" -display none -no-reboot -m 128 &
  qemu_pid=$!
  local i=0
  while [ $i -lt 40 ]; do
    sleep 0.5
    grep -q "$until" "$name.log" 2>/dev/null && break
    i=$((i + 1))
  done
  sleep 0.5
  kill "$qemu_pid" 2>/dev/null
  wait "$qemu_pid" 2>/dev/null
  qemu_pid=
  return 0
}
qemu_pid=
stop_qemu() { [ -n "$qemu_pid" ] && { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }; }
trap stop_qemu EXIT

fail=0
[ "$src_rc" -eq 0 ] || fail=1

boot page_tables '\[jenna\] check exhaustion' || exit 1
log=page_tables.log
for c in "check refusals" "check reclaim at 0x8000000000" "check exhaustion"; do
  line=$(grep -a "^\[jenna\] $c" $log | head -1)
  echo "${line:-missing: [jenna] $c}"
  case "$line" in
    *" ok") ;;
    *) echo "FAIL: [jenna] $c did not end in ok"; fail=1 ;;
  esac
done
if grep -aq "pt_free: kept a frame" $log; then
  echo "FAIL: pt_free met a leaf it does not own"
  fail=1
fi
if grep -aiqE "panic|double fault|out of memory" $log; then
  echo "FAIL: panic or out of memory in the test boot"
  fail=1
fi
if grep -a "page fault:" $log | grep -av "addr=5368709120 " | grep -q .; then
  echo "FAIL: page fault other than the demand-paging probe"
  fail=1
fi
if ! grep -aq "demand paging OK" $log; then
  echo "FAIL: the demand-paging probe did not recover"
  fail=1
fi

# The null-read build. The read follows pt_selftest, so the checks above
# have printed and the kernel tree is complete when it happens.
cd ..
cp "$K/knekt.c0" "$K/knekt.c0.ptbak"
restore() {
  if [ -f "$K/knekt.c0.ptbak" ]; then
    mv -f "$K/knekt.c0.ptbak" "$K/knekt.c0"
  fi
}
trap 'stop_qemu; restore' EXIT
python3 - <<'PY'
p = 'kernel/core/knekt.c0'
s = open(p).read()
marker = '    if (boot_test) { pt_selftest(); }\n'
assert marker in s, "pt_selftest call not found in knekt.c0"
probe = ('    serial_print("null probe: reading address 8\\n");\n'
         '    int null_v = load64(8);\n'
         '    serial_print("null probe: read returned ");\n'
         '    serial_print_int(null_v);\n'
         '    serial_print("\\n");\n')
open(p, 'w').write(s.replace(marker, marker + probe, 1))
PY
if ! ./build.sh >/dev/null 2>&1; then
  restore
  echo "FAIL: building the null-read variant failed"
  exit 1
fi
restore
cd out
boot page_tables_null 'unguarded kernel page fault' || exit 1
nlog=page_tables_null.log
grep -a "null probe\|page fault" $nlog | grep -av "addr=5368709120 " | head -5
if ! grep -aq "^null probe: reading address 8" $nlog; then
  echo "FAIL: the null-read build did not reach its read"
  fail=1
fi
if grep -aq "^null probe: read returned" $nlog; then
  echo "FAIL: a null read in kernel code returned instead of stopping"
  fail=1
fi
if ! grep -aq "^page fault: addr=8 " $nlog || ! grep -aq "^KERNEL PANIC: unguarded kernel page fault" $nlog; then
  echo "FAIL: the null read did not stop at page 0"
  fail=1
fi

# The dry-fault build. The free list and the bump range are both emptied,
# so the demand fault at 5GB plus one page finds no frame. Its page table
# is the probe's, so no table allocation comes before the frame.
cd ..
cp "$K/knekt.c0" "$K/knekt.c0.ptbak"
python3 - <<'PY'
p = 'kernel/core/knekt.c0'
s = open(p).read()
marker = '    if (boot_test) { pt_selftest(); }\n'
assert marker in s, "pt_selftest call not found in knekt.c0"
probe = ('    serial_print("dry fault: touching 5GB plus one page with jenna dry\\n");\n'
         '    pmm_free_head = 0;\n'
         '    pmm_free_count = 0;\n'
         '    pmm_limit = pmm_next;\n'
         '    int dry_v = load64(FAULT_TEST_VIRT + 4096);\n'
         '    serial_print("dry fault: read returned ");\n'
         '    serial_print_int(dry_v);\n'
         '    serial_print("\\n");\n')
open(p, 'w').write(s.replace(marker, marker + probe, 1))
PY
if ! ./build.sh >/dev/null 2>&1; then
  restore
  echo "FAIL: building the dry-fault variant failed"
  exit 1
fi
restore
cd out
boot page_tables_dry 'unguarded kernel page fault\|^dry fault: read returned' || exit 1
dlog=page_tables_dry.log
grep -a "dry fault\|page fault" $dlog | grep -av "addr=5368709120 " | head -5
if ! grep -aq "^dry fault: touching" $dlog; then
  echo "FAIL: the dry-fault build did not reach its read"
  fail=1
fi
if grep -aq "^dry fault: read returned" $dlog; then
  echo "FAIL: a demand fault with no page left returned instead of stopping"
  fail=1
fi
if ! grep -aq "^page fault: addr=5368713216 " $dlog || ! grep -aq "^KERNEL PANIC: unguarded kernel page fault" $dlog; then
  echo "FAIL: the demand fault with jenna dry did not stop on the missing page"
  fail=1
fi

# The ordinary kernel is built again so build/ is left as the tree is.
cd ..
./build.sh >/dev/null 2>&1 || { echo "FAIL: rebuilding the ordinary kernel"; exit 1; }

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: page-table builders refuse, reclaim and fail cleanly, page 0 stays unmapped"
  exit 0
fi
echo "FAIL: see above"
echo "--- $log ---"
grep -a "^\[jenna\]\|^Paging\|^demand\|^page fault" out/$log | head -20
exit 1
