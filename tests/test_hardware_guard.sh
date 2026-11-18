#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
./build.sh
python3 tests/test_hardware_guard.py --evidence out/hardware-guard
