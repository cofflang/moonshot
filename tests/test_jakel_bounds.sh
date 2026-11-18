#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
./build.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/iso/boot/grub"
cp build/moonshot.elf "$scratch/iso/boot/"
cp kernel/core/grub_test.cfg "$scratch/iso/boot/grub/grub.cfg"
grub-mkrescue -o "$scratch/test.iso" "$scratch/iso" >"$scratch/grub.log" 2>&1
python3 - "$scratch" <<'PY'
import pathlib, subprocess, sys
p = pathlib.Path(sys.argv[1])
try:
    subprocess.run(['qemu-system-x86_64', '-cdrom', str(p/'test.iso'), '-serial', 'file:'+str(p/'serial.log'), '-display', 'none', '-no-reboot', '-m', '128', '-monitor', 'none'], timeout=12, check=False)
except subprocess.TimeoutExpired:
    pass
log = (p/'serial.log').read_text()
lines = [s for s in log.splitlines() if 'bounds' in s or 'fault' in s or 'PANIC' in s]
print('\n'.join(lines))
sys.exit(0 if '[jakel] bounds PASS' in log and '[jakel] bounds FAILED' not in log else 1)
PY
