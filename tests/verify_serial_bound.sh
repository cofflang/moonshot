#!/usr/bin/env bash
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
python3 tests/serial_bound.py
