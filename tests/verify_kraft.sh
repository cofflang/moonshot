#!/usr/bin/env bash
# Copyright (C) 2026 tavro
set -eu
python3 "$(dirname "$0")/verify_kraft.py" "$@"
