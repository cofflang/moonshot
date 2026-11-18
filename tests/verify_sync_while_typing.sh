#!/usr/bin/env bash
#
# verify_sync_while_typing.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# A sync must put every file on the disk, or say that it did not. Two runs,
# each on a fresh disk image that carries only the Moonshot magic. In run 0
# nobody types during the sync, in run 1 120 lines are typed while it runs.
#
#   1. Boot one makes a1.txt to a6.txt with alpha1 to alpha6 in them and
#      copies utsikt.elf to u1.elf to u8.elf, then types sync.
#   2. The sync answers with "[jakel] synced", not with a failure line.
#   3. The disk image itself, read on the host after boot one, holds the
#      superblock and every one of those 14 files byte for byte, at the
#      sectors its node table names. A sync that says synced while sectors
#      are missing fails here as a silent loss.
#   4. Boot two, from the same image, reads a1.txt to a6.txt back.
#
# Every line is typed only after the shell has answered the one before it,
# and boot one starts typing only after both boot-time syncs have answered.
# STRESS=1 keeps the host disk busy with a dsync dd loop the whole time,
# which makes each of QEMU's flushes slow. KEEP=1 keeps the images and logs.
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
[ -f moonshot.iso ] || { echo "FAIL: grub-mkrescue did not produce moonshot.iso"; exit 1; }

qpid=
stress=
cleanup() {
  [ -n "$qpid" ] && kill "$qpid" 2>/dev/null
  [ -n "$stress" ] && { pkill -P "$stress" 2>/dev/null; kill "$stress" 2>/dev/null; }
  rm -f swt.sock swt_stress.bin
}
trap cleanup EXIT

# One boot. Types its lines, each after the shell's answer to the last, and
# "@sync" types sync, with 120 more lines straight after it when typing is 1,
# then waits for the sync's answer. Ends QEMU once every line is answered.
boot() { # disk, serial log, typing during sync (0 or 1), then lines to type
  local disk=$1 log=$2 typing=$3
  shift 3
  rm -f "$log" swt.sock
  qemu-system-x86_64 -cdrom moonshot.iso -serial file:"$log" -display none -no-reboot -m 128 \
    -drive file="$disk",format=raw,if=ide,index=0,media=disk \
    -monitor unix:swt.sock,server,nowait &
  qpid=$!
  python3 -I - "$log" "$typing" "$@" <<'PY'
import os, re, socket, sys, time
log, typing, lines = sys.argv[1], sys.argv[2] == "1", sys.argv[3:]
def text():
    try:
        return open(log, "rb").read().decode("latin-1")
    except OSError:
        return ""
def count(pat):
    return len(re.findall(pat, text(), re.M))
PROMPT = r"^\[sh\] prompt$"
SYNC = r"^\[jakel\] (synced|sync failed|disk left untouched)"
def wait(pat, n, secs, what):
    end = time.time() + secs
    while count(pat) < n:
        if time.time() > end:
            print("  waited %d s for %s, it did not come" % (secs, what))
            return False
        time.sleep(0.1)
    return True
end = time.time() + 30
while not os.path.exists("swt.sock") and time.time() < end:
    time.sleep(0.1)
s = socket.socket(socket.AF_UNIX); s.connect("swt.sock"); time.sleep(0.2); s.recv(9999)
def k(x):
    s.sendall(("sendkey %s\n" % x).encode()); time.sleep(0.05); s.recv(9999)
m = {".": "dot", " ": "spc", "-": "minus"}
if not wait(r"^\[sched\] starting", 1, 120, "the scheduler"): sys.exit(1)
if not wait(SYNC, 2, 300, "the boot-time syncs"): sys.exit(1)
for c in "root": k(c)
k("ret"); k("ret")
if not wait(r"^\[raket\] screen login .* ok=1$", 1, 30, "root login"): sys.exit(1)
if not wait(PROMPT, 1, 30, "the authenticated prompt"): sys.exit(1)
for line in lines:
    if line == "@sync":
        n = count(SYNC)
        for c in "sync": k(c)
        k("ret")
        if typing:
            for i in range(120):
                for c in "echo": k(c)
                k("ret")
        if not wait(SYNC, n + 1, 300, "the answer to sync"): sys.exit(1)
        continue
    n = count(PROMPT)
    for c in line: k(m.get(c, c))
    k("ret")
    if not wait(PROMPT, n + 1, 60, "the answer to " + line): sys.exit(1)
PY
  local result=$?
  kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
  qpid=
  return "$result"
}

if [ -n "${STRESS:-}" ]; then
  ( while :; do dd if=/dev/zero of=swt_stress.bin bs=1M count=300 oflag=dsync 2>/dev/null; done ) &
  stress=$!
fi

ok=1
for typing in 0 1; do
  disk=swt$typing.img
  rm -f "$disk"
  dd if=/dev/zero of="$disk" bs=512 count=20480 2>/dev/null
  python3 -c "f = open('$disk', 'r+b'); f.write(b'JAKELBK\0'); f.close()"
  boot "$disk" swt$typing-1.log $typing "make a1.txt" "make a2.txt" "make a3.txt" "make a4.txt" "make a5.txt" "make a6.txt" \
    "write a1.txt alpha1" "write a2.txt alpha2" "write a3.txt alpha3" "write a4.txt alpha4" \
    "write a5.txt alpha5" "write a6.txt alpha6" \
    "copy utsikt.elf u1.elf" "copy utsikt.elf u2.elf" "copy utsikt.elf u3.elf" "copy utsikt.elf u4.elf" \
    "copy utsikt.elf u5.elf" "copy utsikt.elf u6.elf" "copy utsikt.elf u7.elf" "copy utsikt.elf u8.elf" @sync || exit 1
  # The answer to the typed sync is the last sync line of boot one.
  answer=$(grep -aE '^\[jakel\] (synced|sync failed|disk left untouched)' swt$typing-1.log | tail -1)
  ondisk=$(python3 -I - "$disk" ../build/utsikt.elf <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
host = open(sys.argv[2], "rb").read()
want = {b"a%d.txt" % n: b"alpha%d" % n for n in range(1, 7)}
want.update({b"u%d.elf" % n: host for n in range(1, 9)})
good = 0
if d[:8] == b"JAKELBK\0":
    sec = 17
    for i in range(128):
        e = d[512 + i * 64:512 + i * 64 + 64]
        t, p, sz, nl = struct.unpack("<4q", e[:32])
        name = e[32:32 + nl]
        if t == 1 and sz > 0:
            if want.get(name) == d[sec * 512:sec * 512 + sz]: good += 1
            sec += (sz + 511) // 512
print("%d" % good)
PY
)
  boot "$disk" swt$typing-2.log 0 "echo --file a1.txt" "echo --file a2.txt" \
    "echo --file a3.txt" "echo --file a4.txt" "echo --file a5.txt" "echo --file a6.txt" || exit 1
  back=0
  for n in 1 2 3 4 5 6; do grep -aq "^\[echo\] alpha$n" swt$typing-2.log && back=$((back + 1)); done
  retries=$(grep -ac 'drive still busy, waiting longer' swt$typing-1.log)
  echo "typing=$typing answer='${answer:-none}' files_on_image=$ondisk of 14 read_back=$back of 6 wait_retries=$retries"
  case "$answer" in
    "[jakel] synced"*) [ "$ondisk" = 14 ] || echo "  FAIL silent loss, sync said synced but the image holds $ondisk of 14 files" ;;
    *) echo "  FAIL the sync did not succeed" ;;
  esac
  case "$answer" in "[jakel] synced"*) ;; *) ok=0 ;; esac
  [ "$ondisk" = 14 ] && [ "$back" -eq 6 ] || ok=0
  [ -n "${KEEP:-}" ] || rm -f "$disk"
done
if [ "$ok" -eq 1 ]; then echo "PASS: every file reached the disk image and came back after a reboot, typing or not"; exit 0; fi
echo "FAIL: a sync left files off the disk image"
exit 1
