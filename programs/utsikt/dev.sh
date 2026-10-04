#!/usr/bin/env bash
#
# dev.sh — part of utsikt, a browser engine for the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of utsikt, a browser engine written in c0 for moonshot.
# utsikt is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Builds the utsikt in THIS checkout into a moonshot checkout next to it, and
# then boots it or runs its tests there.
#
# utsikt is a ring-3 program and moonshot cannot receive a file from the
# host, so the only way to run it is to compile it, bake it into the kernel
# as a byte array and boot that kernel. moonshot's gen_programs.sh already
# does all of that and takes UTSIKT_DIR to say where the sources are; this
# script points it here, so you can edit in this repository and never copy a
# file by hand.
#
#   ./dev.sh build   bake this utsikt into the kernel and build it (default)
#   ./dev.sh run     build, then boot a QEMU window and type spawn3 utsikt.elf
#   ./dev.sh test    build, then run every verify_utsikt*.sh in moonshot
#   ./dev.sh test X  build, then run only verify_utsikt_X.sh
#
# The layout it expects is the one moonshot's README describes, with this
# repository beside the other two:
#
#   c0-coff/    the compiler and assembler (cofflang/coff)
#   moonshot/   the kernel (cofflang/moonshot)
#   utsikt/     this
#
# MOONSHOT_DIR overrides where moonshot is. Building rewrites moonshot's
# utsikt_data.c0 (and every other seed, which should come out unchanged),
# so that checkout will show a diff afterwards. That is expected; it is what
# "the kernel now runs your utsikt" looks like.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
MOONSHOT_DIR=${MOONSHOT_DIR:-$here/../moonshot}
cmd=${1:-build}

if [ ! -x "$MOONSHOT_DIR/gen_programs.sh" ]; then
  echo "dev.sh: no moonshot checkout at $MOONSHOT_DIR" >&2
  echo "        clone cofflang/moonshot there, or set MOONSHOT_DIR" >&2
  exit 1
fi
MOONSHOT_DIR=$(cd "$MOONSHOT_DIR" && pwd)
cd "$MOONSHOT_DIR"

build() {
  echo "== baking $here into $MOONSHOT_DIR"
  UTSIKT_DIR="$here" ./gen_programs.sh
  # A new seed changes the kernel's size, which moves the JIT helpers, and a
  # kernel with stale helper addresses crashes at boot without saying why.
  # sync_addrs.sh builds, patches the addresses if they moved, and rebuilds.
  ./sync_addrs.sh
}

case "$cmd" in
  build)
    build
    ;;
  run)
    build
    echo "== log in as root (empty password), then: spawn3 utsikt.elf"
    ./run_graphical.sh
    ;;
  test)
    build
    # Several tests assume disk.img exists, and run_qemu.sh is what makes it.
    [ -f disk.img ] || ./run_qemu.sh >/dev/null
    if [ $# -ge 2 ]; then
      tests=("verify_utsikt_$2.sh")
    else
      tests=(verify_utsikt*.sh)
    fi
    failed=()
    for t in "${tests[@]}"; do
      echo "== $t"
      if ./"$t"; then :; else failed+=("$t"); fi
    done
    echo
    if [ ${#failed[@]} -eq 0 ]; then
      echo "dev.sh: ${#tests[@]}/${#tests[@]} passed"
    else
      echo "dev.sh: $(( ${#tests[@]} - ${#failed[@]} ))/${#tests[@]} passed, failed: ${failed[*]}"
      exit 1
    fi
    ;;
  *)
    echo "usage: ./dev.sh [build | run | test [name]]" >&2
    exit 2
    ;;
esac
