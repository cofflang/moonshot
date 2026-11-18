"""Record tavla open and close cues and their mute controls."""
import os
import re
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = Path(os.environ.get("PLING_EVIDENCE", str(ROOT / "out/pling")))
EVIDENCE.mkdir(parents=True, exist_ok=True)
assert "pling_variant" not in (ROOT / "kernel/drivers/oljud.c0").read_text(), "variant selector remains"
assert "pling=2" not in (ROOT / "kernel/core/knekt.c0").read_text(), "boot variant selector remains"


def run_case(words, label, audible):
    with tempfile.TemporaryDirectory(prefix="moonshot-pling-") as tmp:
        work = Path(tmp)
        grub = work / "iso/boot/grub"
        grub.mkdir(parents=True)
        (grub.parent / "moonshot.elf").write_bytes((ROOT / "build/moonshot.elf").read_bytes())
        (grub / "grub.cfg").write_text(
            'set timeout=0\nmenuentry "pling test" {\n'
            'multiboot /boot/moonshot.elf test ' + words + '\nboot\n}\n')
        subprocess.run(["grub-mkrescue", "-o", str(work / "boot.iso"), str(work / "iso")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        disk = work / "disk.img"
        with disk.open("wb") as f:
            f.truncate(10485760)
        wav = EVIDENCE / (label + ".wav")
        log = EVIDENCE / (label + ".serial")
        monitor = work / "monitor.sock"
        qemu = subprocess.Popen([
            "qemu-system-x86_64", "-cdrom", str(work / "boot.iso"),
            "-drive", f"file={disk},format=raw,if=ide,index=0,media=disk",
            "-serial", "file:" + str(log), "-display", "none", "-no-reboot", "-m", "128",
            "-audiodev", f"wav,id=snd0,path={wav}", "-device", "sb16,audiodev=snd0",
            "-monitor", f"unix:{monitor},server,nowait"],
            stdout=subprocess.DEVNULL, stderr=(EVIDENCE / (label + ".qemu")).open("w"))
        try:
            deadline = time.monotonic() + 30
            while not monitor.exists():
                assert qemu.poll() is None, (EVIDENCE / (label + ".qemu")).read_text()
                assert time.monotonic() < deadline, "monitor timeout"
                time.sleep(0.1)
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(5)
                s.connect(str(monitor))
                s.recv(65536)

                def send(command):
                    s.sendall((command + "\n").encode())
                    time.sleep(0.06)
                    s.recv(65536)

                def word(value):
                    keys = {" ": "spc", "/": "slash", ".": "dot"}
                    for char in value:
                        send("sendkey " + keys.get(char, char))
                    send("sendkey ret")

                time.sleep(3)
                word("root")
                time.sleep(0.5)
                send("sendkey ret")
                time.sleep(2)
                word("start test/mouse.elf")
                time.sleep(1.5)
                send("sendkey alt-tab")
                time.sleep(0.5)
                send("sendkey alt-w")
                time.sleep(2)
                send("quit")
            qemu.wait(timeout=10)
        finally:
            if qemu.poll() is None:
                qemu.kill()
            qemu.wait()
        serial = log.read_text()
        assert "[elf] windowed spawn" in serial, serial[-1500:]
        timing = re.search(r"\[pling\] generator ticks=(\d+)", serial)
        assert timing, "missing generator timing"
        print(label, "generator ticks", timing.group(1), flush=True)
        assert "PANIC" not in serial and "double fault" not in serial
        data = wav.read_bytes()
        assert data[:4] == b"RIFF" and data[8:16] == b"WAVEfmt " and data[36:40] == b"data"
        channels, rate = struct.unpack("<HI", data[22:28])
        assert struct.unpack("<H", data[34:36])[0] == 16
        raw = data[44:]
        raw = raw[:len(raw) - len(raw) % (2 * channels)]
        with wave.open(str(wav), "wb") as f:
            f.setnchannels(channels)
            f.setsampwidth(2)
            f.setframerate(rate)
            f.writeframes(raw)
        samples = struct.unpack("<%dh" % (len(raw) // 2), raw)[::channels]
        active = [i for i, value in enumerate(samples) if abs(value) > 128]
        bursts = []
        for i in active:
            if not bursts or i - bursts[-1][1] > rate // 4:
                bursts.append([i, i])
            else:
                bursts[-1][1] = i
        print(label, "bursts", [(round(a / rate, 3), round(b / rate, 3)) for a, b in bursts], flush=True)
        if audible:
            assert len(bursts) == 2, "expected separate open and close bursts"
            for a, b in bursts:
                assert 0.03 < (b - a) / rate < 0.4, "cue duration outside bounds"
            for (a, b), pitches in zip(bursts, [(440, 660), (660, 440)]):
                for offset, frequency in zip([.025, .125], pitches):
                    start = a + int(offset * rate)
                    chunk = samples[start:start + int(.04 * rate)]
                    measured = sum(x <= 0 < y for x, y in zip(chunk, chunk[1:])) / .04
                    assert abs(measured - frequency) < 45, (label, measured, frequency)
            assert 1 < (bursts[1][0] - bursts[0][0]) / rate < 4
        else:
            assert not active, "mute control was audible"


run_case("pling", "selected-pair", True)
if not os.environ.get("PLING_RED_ONLY"):
    run_case("pling tyst", "muted", False)
    run_case("", "test-default", False)
print("PASS pling recordings and controls", flush=True)
