#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
"""Exercise retained shell prompts through the QEMU monitor and count pixels."""
import pathlib
import shutil
import select
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[1]
out = (root / sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
# Probe empty authenticated and login-gate windows after shell allocation.
# Restore the source before starting QEMU, including when the build fails.
knekt = root / "kernel/core/knekt.c0"
original = knekt.read_bytes()
marker = b"    shell_init();\n"
assert original.count(marker) == 1
try:
    knekt.write_bytes(original.replace(marker, marker +
                      (root / "tests/fixtures/prompt_reflow.c0").read_bytes()))
    subprocess.run([str(root / "build.sh")], cwd=root, check=True)
finally:
    knekt.write_bytes(original)

iso = out / "iso"
(iso / "boot/grub").mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / "build/moonshot.elf", iso / "boot/moonshot.elf")
shutil.copyfile(root / "kernel/core/grub_test.cfg", iso / "boot/grub/grub.cfg")
with (out / "grub.log").open("w") as log:
    subprocess.run(["grub-mkrescue", "-o", str(out / "test.iso"), str(iso)],
                   stdout=log, stderr=subprocess.STDOUT, check=True)

failures = []

def check(ok, message):
    print(("PASS " if ok else "FAIL ") + message, flush=True)
    if not ok:
        failures.append(message)

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-cdrom", str(out / "test.iso"),
    "-serial", "file:" + str(out / "serial.log"), "-display", "none",
    "-no-reboot", "-m", "128", "-monitor", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
try:
    time.sleep(3)
    def response():
        reply = b""
        while b"(qemu)" not in reply:
            assert select.select([qemu.stdout], [], [], 5)[0], "monitor timeout"
            chunk = qemu.stdout.read1(65536)
            assert chunk, "monitor exited"
            reply += chunk
    response()

    def send(command, settle=0.15):
        qemu.stdin.write((command + "\n").encode())
        qemu.stdin.flush()
        response()
        time.sleep(settle)

    def word(text):
        keys = {" ": "spc", ".": "dot", "/": "slash", "\n": "ret"}
        for char in text:
            send("sendkey " + keys.get(char, char))

    def shot(name):
        path = out / (name + ".ppm")
        send("screendump " + str(path), 0.3)
        magic, size, maximum, pixels = path.read_bytes().split(b"\n", 3)
        assert magic == b"P6" and maximum == b"255"
        w, h = map(int, size.split())
        assert len(pixels) == w * h * 3
        return w, h, pixels

    def dim_cell(image, x, y):
        w, _, pixels = image
        return bytes(pixels[((y + dy) * w + x + dx) * 3:
                            ((y + dy) * w + x + dx) * 3 + 3] == b"ddd"
                     for dy in range(8) for dx in range(8))

    def prompts(image):
        w, h, _ = image
        found = []
        # The shell is the left tile. Match all five glyphs, including
        # adjacent duplicates on the same line, and exclude the status bar.
        for y in range(0, h - 8, 8):
            for x in range(0, w // 2 - 39, 8):
                if dim_cell(image, x, y) == template[0] and all(
                    dim_cell(image, x + i * 8, y) == template[i]
                    for i in range(1, 5)
                ):
                    found.append((x, y))
        return found

    def count(name):
        positions = prompts(shot(name))
        check(len(positions) == 1, name + " prompt glyph positions " + str(positions))

    word("root\n")
    time.sleep(0.5)
    word("\n")
    time.sleep(1)
    word("clear\n")
    baseline = shot("baseline")
    template = [dim_cell(baseline, x * 8, 0) for x in range(5)]
    check(all(any(cell) for cell in template), "baseline has five dim root> glyphs")
    count("before_spawn")
    word("start hylla.elf\n")
    time.sleep(3)
    # Remove command history so every remaining prompt is idle and must
    # remain unique through all the following window events.
    word("clear\n")
    count("before_maximize")
    send("sendkey alt-tab", 1)
    for cycle in range(2):
        prior = (out / "serial.log").read_bytes().count(b"[sh] prompt")
        send("sendkey alt-m", 1)
        shot("maximized_" + str(cycle))
        check((out / "serial.log").read_bytes().count(b"[sh] prompt") == prior,
              "maximizing does not prompt into the hidden shell")
        send("sendkey alt-m", 1)
        count("restored_" + str(cycle))
    send("sendkey alt-w", 1.5)
    count("closed")
    serial = (out / "serial.log").read_text(errors="replace")
    for case in range(3):
        check("[prompt-test] case=" + str(case) + " bad=0" in serial,
              "cleared session reprompts once for stage " + str(case))
    check(serial.count("kakel maximized: win=") == 4, "four maximize toggles reached kakel")
    check("[tavla] closed win=" in serial, "Alt+W reached tavla close")
    # A successful split creates an empty shell that really needs a prompt.
    word("split\n")
    image = shot("split")
    w, h, pixels = image
    right = (w, h, b"".join(pixels[y*w*3+w//2*3:(y+1)*w*3] +
                           bytes(w//2*3) for y in range(h)))
    check(len(prompts(right)) == 1, "new empty split shell receives one prompt")
    # The shell that ran split keeps its line and prompts once below it.
    left = prompts(image)
    check(left == [(0, 0), (0, 8)], "the shell that split prompts again " + str(left))
finally:
    qemu.terminate()
    try:
        qemu.wait(timeout=5)
    except subprocess.TimeoutExpired:
        qemu.kill()
        qemu.wait()

sys.exit(bool(failures))
