#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."

source=kernel/shell/jit.c0
wide=$(grep -F -c 'serial_putc(load64(name_ptr + ci))' "$source" || true)
byte=$(grep -F -c 'serial_putc(load8(name_ptr + ci))' "$source" || true)

if [ "$wide" -ne 0 ] || [ "$byte" -ne 2 ]; then
  echo "FAIL: JIT variable-name diagnostics need two byte-wide reads"
  echo "wide reads: $wide"
  echo "byte reads: $byte"
  exit 1
fi

echo "PASS: source guard finds two byte-wide JIT diagnostic reads"
