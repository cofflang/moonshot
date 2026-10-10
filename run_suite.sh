#!/usr/bin/env bash
#
# run_suite.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Runs the whole suite (run_qemu.sh, test_*.sh, verify_*.sh) on a snapshot
# of the tree, several scripts at a time.
#
#   ./run_suite.sh            all scripts, 3 at a time
#   ./run_suite.sh -j 1       one at a time, like the plain loop
#   ./run_suite.sh verify_utsikt_img.sh test_keyboard.sh
#
# Why a snapshot. Every script writes into this directory, moonshot.elf,
# moonshot.iso, serial.log, disk.img, the programs in build/. Two of them
# at once overwrite each other, and editing a source file while the suite
# runs means the later scripts test a mixture of the previous and the new code.
# So the tree is copied once, at the start, and the suite never sees an edit
# made after that. Each parallel job gets its own copy for the same reason.
#
# Why at most 3 by default. Most of the suite's time is not the build but
# QEMU running in real time, with fixed sleeps, keys typed one by one through the
# monitor. Those scripts are timing-sensitive, and a loaded machine slows
# the guest without slowing the sleeps. Every script that fails in parallel
# is therefore run once more, alone, and the report says which failures held
# up and which only happened under load. A failure that only happens under
# load is still worth a look, but it is not a regression.
#
# It copies ../c0-coff next to the snapshot, and ../gnista and ../utsikt when
# they are there (a dev tree), because build.sh and the generators find them
# there.
set -u
cd "$(dirname "$0")"

jobs=3
if [ "${1:-}" = "-j" ]; then jobs="$2"; shift 2; fi
if [ $# -gt 0 ]; then scripts=("$@"); else scripts=(run_qemu.sh test_*.sh verify_*.sh); fi

here=$(pwd)
code=$(dirname "$here")
snap=$(mktemp -d "${TMPDIR:-/tmp}/moonshot-suite.XXXXXX")
echo "snapshot: $snap"

# Build outputs, recordings and old images are left out. They are most of
# the directory's size, and every script regenerates what it needs.
copy_tree() { # src-dir dest-dir
  mkdir -p "$2"
  tar -C "$1" --exclude=./release --exclude=./.git --exclude='*.iso' \
      --exclude=isoroot --exclude='*.img' --exclude='*.log' --exclude='*.wav' \
      --exclude='*.sock' -cf - . | tar -C "$2" -xf -
}

base=$snap/base
for d in moonshot c0-coff gnista utsikt; do
  [ -d "$code/$d" ] && copy_tree "$code/$d" "$base/$d"
done

# One build up front, so a toolchain rebuild and its bootstrap audit happen
# once rather than in every shard at the same time.
if ! (cd "$base/moonshot" && ./build.sh >"$snap/build.log" 2>&1); then
  echo "FAIL: build.sh in the snapshot, see $snap/build.log"
  tail -20 "$snap/build.log"
  exit 1
fi

for i in $(seq 1 "$jobs"); do cp -a "$base" "$snap/shard$i"; done
mkdir -p "$snap/logs"

# The longest scripts go first, so a long one does not start last and leave
# the other shards idle at the end.
slow="test_repl.sh verify_elf_backend.sh verify_utsikt_reload.sh"
ordered=()
for s in $slow; do
  for t in "${scripts[@]}"; do [ "$t" = "$s" ] && ordered+=("$t"); done
done
for t in "${scripts[@]}"; do
  case " $slow " in *" $t "*) ;; *) ordered+=("$t") ;; esac
done
printf '%s\n' "${ordered[@]}" > "$snap/queue"
: > "$snap/results"

# Each shard takes the next script off the queue until it is empty. flock
# makes taking one atomic, so no script runs twice or not at all.
worker() { # shard-number
  local dir=$snap/shard$1/moonshot t start
  while true; do
    t=$(flock "$snap/queue" sh -c 'head -1 "$1"; sed -i 1d "$1"' _ "$snap/queue")
    [ -n "$t" ] || return 0
    start=$(date +%s)
    if (cd "$dir" && "./$t") >"$snap/logs/$t.log" 2>&1; then r=PASS; else r=FAIL; fi
    line=$(printf '%s %-32s %4ss  shard %s' "$r" "$t" "$(( $(date +%s) - start ))" "$1")
    echo "$line"
    flock "$snap/results" sh -c 'echo "$1" >> "$2"' _ "$line" "$snap/results"
  done
}

t0=$(date +%s)
for i in $(seq 1 "$jobs"); do worker "$i" & done
wait

mapfile -t failed < <(awk '$1=="FAIL"{print $2}' "$snap/results")
held=()
if [ "${#failed[@]}" -gt 0 ] && [ "$jobs" -gt 1 ]; then
  echo
  echo "re-running ${#failed[@]} failure(s) alone..."
  for t in "${failed[@]}"; do
    if (cd "$snap/shard1/moonshot" && "./$t") >"$snap/logs/$t.alone.log" 2>&1; then
      echo "  PASS alone: $t (failed only under load, see logs/$t.log)"
    else
      echo "  FAIL alone: $t"
      held+=("$t")
    fi
  done
else
  held=("${failed[@]}")
fi

total=${#ordered[@]}
echo
echo "$(( total - ${#held[@]} ))/$total passed in $(( $(date +%s) - t0 ))s ($jobs at a time)"
echo "logs: $snap/logs"
[ "${#held[@]}" -eq 0 ] || { echo "failed: ${held[*]}"; exit 1; }
# The copies are about 100MB each. Kept after a failure, for a look at what
# the failing script left behind; after a clean run only the logs are kept.
rm -rf "$base" "$snap"/shard*
exit 0
