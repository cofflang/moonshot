#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
./build.sh
python3 tests/screensaver.py
python3 tests/screensaver.py --four-tiles
python3 tests/screensaver_shapes.py
