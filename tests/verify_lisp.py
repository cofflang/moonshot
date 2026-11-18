#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# Distributed under the GNU General Public License version 3 or later.
# Run only the Lisp ELF against an already built kernel.
import pathlib
import re
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(kernel, output, name="et31"):
    with tempfile.TemporaryDirectory(prefix="lisp-") as directory:
        tmp = pathlib.Path(directory)
        boot = tmp / "iso/boot"
        (boot / "grub").mkdir(parents=True)
        shutil.copyfile(kernel, boot / "moonshot.elf")
        shutil.copyfile(ROOT / "kernel/core/grub_test.cfg", boot / "grub/grub.cfg")
        subprocess.run(["grub-mkrescue", "-o", str(tmp / "test.iso"), str(tmp / "iso")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        with (tmp / "disk.img").open("wb") as disk:
            disk.truncate(10 * 1024 * 1024)
        serial = tmp / "serial.log"
        proc = subprocess.Popen([
            "qemu-system-x86_64", "-cdrom", str(tmp / "test.iso"),
            "-drive", f"file={tmp / 'disk.img'},format=raw,if=ide,index=0,media=disk",
            "-serial", f"file:{serial}", "-display", "none", "-no-reboot", "-m", "128",
            "-monitor", f"unix:{tmp / 'monitor'},server,nowait"],
            stdout=subprocess.DEVNULL, stderr=None)
        try:
            deadline = time.monotonic() + 30
            while not (tmp / "monitor").exists():
                if time.monotonic() > deadline or proc.poll() is not None:
                    raise RuntimeError("QEMU monitor unavailable")
                time.sleep(0.1)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
                monitor.connect(str(tmp / "monitor"))
                monitor.settimeout(5)
                time.sleep(3)
                monitor.recv(65536)

                def send(key):
                    monitor.sendall(f"sendkey {key}\n".encode())
                    time.sleep(0.08)
                    monitor.recv(65536)

                def word(text):
                    keys = {" ": "spc", ".": "dot", "/": "slash"}
                    for char in text:
                        send(keys.get(char, char))

                word("root")
                send("ret")
                time.sleep(0.5)
                send("ret")
                time.sleep(1.5)
                word(f"start test/{name}.elf")
                send("ret")
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    data = serial.read_bytes()
                    found = re.findall(rb"\[syscall\] exit code=(-?\d+)", data)
                    if found:
                        return int(found[-1])
                    if b"[fault]" in data or proc.poll() is not None:
                        break
                    time.sleep(0.1)
                raise RuntimeError("Lisp ELF did not return an exit code within 25 seconds")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            if serial.exists():
                shutil.copyfile(serial, output)


if __name__ == "__main__":
    import sys
    manifest = (ROOT / "tests/elf/manifest.txt").read_text().splitlines()
    name = next(line.split()[0] for line in manifest if " 32_lisp.c0 " in line)
    output = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "out/lisp-serial.log"
    code = run(ROOT / "build/moonshot.elf", output, name)
    print(f"32_lisp.c0 exit {code}, expected 0")
    sys.exit(0 if code == 0 else 1)
