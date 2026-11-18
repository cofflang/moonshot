#!/usr/bin/env bash
# Copyright (C) 2026 tavro
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
python3 "$root/tests/verify_site_tools.py" "$@"
if [ "$#" = 0 ]; then
  python3 "$root/tests/verify_site_retry.py"
fi
