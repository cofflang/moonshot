#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
./build.sh
python3 tests/verify_pling.py
