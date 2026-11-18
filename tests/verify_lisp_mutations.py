#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# Distributed under the GNU General Public License version 3 or later.
# Compile isolated guard mutations and run only the Lisp test.
import pathlib
import subprocess
import tempfile
import sys

from verify_lisp import ROOT, run


def command(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    coff = ROOT.parent / "c0-coff/coff1"
    smed = ROOT.parent / "c0-coff/smed"
    source = (ROOT.parent / "gnista/lisp.c0").read_text()
    test = (ROOT / "tests/elf/32_lisp.c0").read_text()
    cases = [
        ("reader", "if (v.pos >= v.len) { tmp_lisp_fail(v, 7); }", "if (0) { tmp_lisp_fail(v, 7); }", 16),
        ("integer", "if (n < -922337203685477580 || (n == -922337203685477580 && d > last))", "if (0)", 17),
        ("depth", "if (v.depth >= 48) { return tmp_lisp_fail(v, 6); }", "if (0) { return tmp_lisp_fail(v, 6); }", 12),
        ("fuel", "if (v.fuel <= 0)", "if (0)", 14),
        ("arena", "return tmp_lisp_fail(v, 3);", "return 1;", 41),
        ("size", "len > 16384", "len > 20000", 30),
        ("roots", "tmp_lisp_root(v, x); tmp_lisp_root(v, env);", "tmp_lisp_root(v, 0); tmp_lisp_root(v, 0);", 2),
        ("handles", "if (x < 1 || x > v.cap)", "if (0)", 28),
        ("root_limit", "if (v.nr >= 2048)", "if (0)", 29),
    ]
    cases.extend([
        ("file_reader", "if (v.pos >= v.len) { tmp_lisp_fail(v, 7); }", "if (0) { tmp_lisp_fail(v, 7); }", 35),
        ("file_integer", "if (n < -922337203685477580 || (n == -922337203685477580 && d > last))", "if (0)", 36),
        ("file_ascii", "if ((c < 32 && c != 9 && c != 10 && c != 13) || c > 126)", "if (0)", 37),
        ("file_size", "16384", "20000", 32),
    ])
    if len(sys.argv) > 1:
        cases = [case for case in cases if case[0] in sys.argv[1:]]
        if not cases:
            raise RuntimeError("No matching mutation cases")
    pack = ROOT / "build/elf_tests.pack"
    original_pack = pack.read_bytes()
    with tempfile.TemporaryDirectory(prefix="lisp-mutations-") as directory:
        tmp = pathlib.Path(directory)
        args = []
        for index, (label, before, after, expected) in enumerate(cases, 1):
            if before not in source:
                raise RuntimeError(f"Mutation target missing for {label}")
            folder = tmp / label
            folder.mkdir()
            (folder / "lisp.c0").write_text(source.replace(before, after))
            fixture = test
            if label == "file_reader":
                fixture = fixture.replace('if (v.error != 7 || v.line != 1 || v.column != 3)', 'if (0)')
            if label == "file_integer":
                fixture = fixture.replace('if (v.error != 8) { return 17; }', '')
                fixture = fixture.replace('if (v.error != 8) { return 18; }', '')
            if label == "file_size":
                fixture = fixture.replace('if (v.error != 13) { return 30; }', '')
            if label == "depth":
                # Independent fuel bounds the deliberately unguarded recursion.
                fixture = fixture.replace('tmp_lisp_eval(v, "(define (f) (f)) (f)");',
                                          'v.budget = 120; tmp_lisp_eval(v, "(define (f) (f)) (f)");')
            (folder / "test.c0").write_text(fixture)
            command(coff, "--elf", "-I", folder, folder / "test.c0", folder / "test.s")
            command(smed, "--base", "0x80000000", folder / "test.s", folder / "test.elf")
            args.extend([f"et{index:02}", f"{label}.c0", str(expected), folder / "test.elf"])
        command(coff, ROOT / "tools/bake.c0", tmp / "bake.s")
        command(smed, tmp / "bake.s", tmp / "bake")
        (tmp / "bake").chmod(0o700)
        try:
            command(tmp / "bake", "pack", pack, tmp / "manifest", *args)
            command(coff, ROOT / "kernel/core/kmain.c0", tmp / "kmain.s")
            command(smed, "-T", ROOT / "kernel/core/linker.ld", ROOT / "kernel/core/boot.s",
                    tmp / "kmain.s", ROOT / "kernel/core/ring3_handlers.s", tmp / "kernel.elf")
        finally:
            pack.write_bytes(original_pack)
        failed = False
        for index, (label, _, _, expected) in enumerate(cases, 1):
            actual = run(tmp / "kernel.elf", tmp / f"{label}.log", f"et{index:02}")
            print(f"{label} disabled exit {actual}, expected rejection exit {expected}", flush=True)
            if actual != expected:
                failed = True
        return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
