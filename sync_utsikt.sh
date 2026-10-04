#!/usr/bin/env bash
#
# sync_utsikt.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Keeps programs/utsikt/ in step with utsikt's own repository.
#
# utsikt, the browser, is developed in its own repository and carried here
# as a git subtree, squashed, so that a moonshot clone builds on its own and
# every byte of the browser the kernel bakes in has its source in this
# tree. The subtree merge commits record which utsikt commit each copy came
# from, which is the provenance a byte array needs.
#
#   ./sync_utsikt.sh [ref]          pull utsikt's ref (default main) into
#                                   programs/utsikt/, then rebuild the seed
#                                   and the kernel from it
#   ./sync_utsikt.sh --check [ref]  say whether programs/utsikt/ matches
#                                   utsikt's ref, and change nothing
#   ./sync_utsikt.sh --send branch  push the changes made to programs/utsikt/
#                                   in this repository to a branch of utsikt,
#                                   to open a pull request from there
#
# UTSIKT_REPO says where utsikt is, as a URL or a path to a local clone.
set -eu
cd "$(dirname "$0")"

UTSIKT_REPO=${UTSIKT_REPO:-https://github.com/cofflang/utsikt.git}
prefix=programs/utsikt

if [ "$(git rev-parse --show-toplevel)" != "$(pwd -P)" ]; then
  echo "sync_utsikt.sh: run this from a git clone of moonshot" >&2
  exit 1
fi

# git subtree refuses to work over uncommitted changes, and a check against
# a dirty copy would not be checking what is committed.
dirty() {
  [ -n "$(git status --porcelain -- "$prefix")" ]
}

case "${1:-}" in
  --check)
    ref=${2:-main}
    git fetch -q "$UTSIKT_REPO" "$ref"
    if dirty; then
      echo "sync_utsikt.sh: $prefix has uncommitted changes:"
      git status --short -- "$prefix"
      exit 1
    fi
    if git diff --quiet "HEAD:$prefix" FETCH_HEAD^{tree}; then
      echo "sync_utsikt.sh: $prefix matches utsikt $ref ($(git rev-parse --short FETCH_HEAD))"
    else
      echo "sync_utsikt.sh: $prefix differs from utsikt $ref ($(git rev-parse --short FETCH_HEAD)):"
      git diff --stat "HEAD:$prefix" FETCH_HEAD^{tree}
      echo "  ./sync_utsikt.sh $ref     to take utsikt's version"
      echo "  ./sync_utsikt.sh --send <branch>   if the changes were made here"
      exit 1
    fi
    ;;
  --send)
    branch=${2:?usage: ./sync_utsikt.sh --send <branch>}
    if [ "$branch" = main ]; then
      echo "sync_utsikt.sh: send to a branch and open a pull request, not to main" >&2
      exit 1
    fi
    git subtree push --prefix="$prefix" "$UTSIKT_REPO" "$branch"
    ;;
  -*)
    echo "usage: ./sync_utsikt.sh [ref] | --check [ref] | --send <branch>" >&2
    exit 2
    ;;
  *)
    ref=${1:-main}
    if dirty; then
      echo "sync_utsikt.sh: commit or discard the changes in $prefix first" >&2
      exit 1
    fi
    git subtree pull --prefix="$prefix" "$UTSIKT_REPO" "$ref" --squash \
      -m "Update utsikt to $ref"
    # A new utsikt means a new seed, a new seed means a kernel of a new
    # size, and a kernel of a new size has stale JIT helper addresses until
    # sync_addrs.sh patches them.
    ./gen_programs.sh
    ./sync_addrs.sh
    echo
    echo "sync_utsikt.sh: utsikt $ref is in $prefix and baked into the kernel."
    echo "Run the verify_utsikt*.sh tests, then commit utsikt_data.c0 and kmain.c0."
    ;;
esac
