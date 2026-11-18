#!/usr/bin/env bash
# Copyright (C) 2026 tavro
# Exercise the production sprite loader with an in-memory file provider.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
paint = root / "programs/utsikt/paint.c0" if (root / "programs/utsikt/paint.c0").exists() else root.parent / "utsikt/paint.c0"
print("paint.c0 sha256", hashlib.sha256(paint.read_bytes()).hexdigest(), flush=True)
with tempfile.TemporaryDirectory(prefix="moonshot-spr-bounds.") as directory:
    work = Path(directory)
    (work / "paint.c0").write_text(paint.read_text()
        .replace("readfile(", "fixture_readfile(")
        .replace("glyph(", "fixture_glyph("))
    (work / "test.c0").write_text('''
int sample;
int sample_size;
int doc_alloc(int n) { return alloc(n); }
int fixture_glyph(int c, int p) { return 0; }
int fixture_readfile(int name, int dest, int cap) {
    if (!dest) { return sample_size; }
    int i = 0;
    for (i = 0; i < sample_size && i < cap; i += 1) {
        dest[i] = sample[i];
    }
    return sample_size;
}
include "paint.c0";
int check(int w, int h, int frames, int size, int accept) {
    store64(sample, w);
    store64(sample + 8, h);
    store64(sample + 16, frames);
    sample_size = size;
    int image = img_load("fixture.spr");
    int got = image != 0;
    if (got != accept) {
        print("FAIL sprite header acceptance\\n");
        return 1;
    }
    return 0;
}
int main() {
    sample = alloc(128);
    int failures = 0;
    failures += check(1, 1, 1, 28, 1);
    failures += check(2, 2, 2, 56, 1);
    failures += check(2, 2, 2, 55, 0);
    failures += check(2, 2, 1, 28, 0);
    failures += check(1, 1, 1, 27, 0);
    failures += check(0, 1, 1, 28, 0);
    failures += check(1, 0, 1, 28, 0);
    failures += check(1, 1, 0, 28, 0);
    failures += check(1, 1, -1, 28, 0);
    failures += check(4097, 1, 1, 28, 0);
    failures += check(1, 4097, 1, 28, 0);
    failures += check(1, 1, 4611686018427387904, 28, 0);
    failures += check(4096, 4096, 274877906944, 28, 0);
    failures += check(1, 1, 9223372036854775807, 28, 0);
    failures += check(1, 1, 1, 2097153, 0);
    if (failures) { return 1; }
    print("PASS 15 production sprite loader cases\\n");
    return 0;
}
''')
    compiler = root.parent / "c0-coff/coff1"
    assembler = root.parent / "c0-coff/smed"
    subprocess.run([str(compiler), "test.c0", "test.s"], cwd=work, check=True)
    subprocess.run([str(assembler), "test.s", "test"], cwd=work, check=True)
    (work / "test").chmod(0o700)
    result = subprocess.run([str(work / "test")], cwd=work, timeout=10)
    sys.exit(result.returncode)
PY
