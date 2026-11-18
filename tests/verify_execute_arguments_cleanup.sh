#!/usr/bin/env bash
#
# verify_execute_arguments_cleanup.sh — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
set -eu
python3 "$(dirname "$0")/verify_execute_arguments_cleanup.py"
python3 "$(dirname "$0")/verify_execute_arguments_serial.py"
