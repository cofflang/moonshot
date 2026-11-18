#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
python3 "$root/tests/verify_site_followup.py" "$@"
