#!/usr/bin/env bash
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
# Count actual prompt glyphs across window events in a headless framebuffer.
set -eu
cd "$(dirname "$0")/.."
python3 tests/prompt_reflow.py "${1:-out/prompt-reflow}"
