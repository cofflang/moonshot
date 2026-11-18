import pathlib
import re
import socket
import sys
import subprocess
import tempfile
import time

four_tiles = "--four-tiles" in sys.argv
serial_name = "BL-009B-four-serial.log" if four_tiles else "BL-009B-serial.log"
root = pathlib.Path(__file__).resolve().parents[1]
(root / "build/evidence").mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="moonshot-dvala-") as temp:
    work = pathlib.Path(temp)
    boot = work / "iso/boot"
    (boot / "grub").mkdir(parents=True)
    (boot / "moonshot.elf").write_bytes((root / "build/moonshot.elf").read_bytes())
    (boot / "grub/grub.cfg").write_bytes((root / "kernel/core/grub_test.cfg").read_bytes())
    subprocess.run(["grub-mkrescue", "-o", str(work / "boot.iso"), str(work / "iso")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    serial = work / "serial.log"
    proc = subprocess.Popen(["qemu-system-x86_64", "-cdrom", str(work / "boot.iso"), "-serial", "file:" + str(serial), "-display", "none", "-no-reboot", "-m", "128", "-monitor", "unix:" + str(work / "monitor") + ",server,nowait"])
    try:
        time.sleep(4)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(str(work / "monitor"))
        sock.recv(65536)
        def send(command, delay=0.12):
            sock.sendall((command + "\n").encode())
            time.sleep(delay)
            sock.recv(65536)
        def word(text):
            mapping = {" ": "spc", ".": "dot", "/": "slash", "_": "shift-minus"}
            for char in text:
                send("sendkey " + mapping.get(char, char))
        def shot(name):
            path = root / "build/evidence" / (name + ".ppm")
            send("screendump " + str(path), 0.3)
            return path.read_bytes().split(b"\n", 3)[3]
        word("root")
        send("sendkey ret")
        send("sendkey ret", 1)
        assert "[dvala] running" not in serial.read_text(errors="replace"), "saver enabled itself at boot"
        if four_tiles:
            for _ in range(3):
                word("start test/mouse.elf")
                send("sendkey ret", 1.5)
            log = serial.read_text(errors="replace")
            assert log.count("[elf] windowed spawn wid=") == 3, "four-tile setup failed"
            before = shot("BL-009B-four-before")
            word("dvala 2")
            send("sendkey ret", 4)
            log = serial.read_text(errors="replace")
            assert "[dvala] running" in log, "four occupied tiles prevented idle start"
            running = shot("BL-009B-four-running")
            moving = shot("BL-009B-four-moving")
            assert running != moving and any(running), "four-tile starfield does not animate"
            black = sum(running[i:i+3] == b"\0\0\0" for i in range(0, len(running), 3))
            assert black > len(running) // 3 * 0.97, "four-tile saver does not cover the screen"
            send("sendkey x", 0.7)
            word("dvala off")
            send("sendkey ret", 0.5)
            word("echo fourawake")
            send("sendkey ret", 0.5)
            after = shot("BL-009B-four-restored")
            log = serial.read_text(errors="replace")
            tid = re.search(r"\[dvala\] running task=(\d+)", log).group(1)
            assert "[dvala] stopped" in log, "four-tile saver did not stop"
            assert "[sched] reaped task " + tid + " stack=" in log.split("[dvala] running task=", 1)[1], "four-tile saver was not reaped"
            assert "[sh] fourawake\n" in log and "unknown command: xdvala" not in log, "four-tile wake leaked or shell focus was lost"
            for x, y in [(256, 180), (768, 180), (256, 560), (768, 560)]:
                region = lambda frame: b"".join(frame[(row * 1024 + x - 32)*3:(row * 1024 + x + 32)*3] for row in range(y-32, y+32))
                assert region(before) == region(after), "tile interior was not restored"
            for _ in range(3):
                send("sendkey alt-tab", 0.3)
                send("sendkey alt-ret", 0.4)
                full = shot("BL-009B-four-probe")
                assert full == bytes.fromhex("101418") * (len(full) // 3), "original graphical tile was lost"
                send("sendkey alt-ret", 0.4)
            send("sendkey alt-tab", 0.3)
            word("echo fourfocus")
            send("sendkey ret", 0.4)
            assert "[sh] fourfocus\n" in serial.read_text(errors="replace"), "four-tile focus cycle did not return to shell"
            print("PASS four occupied tiles, idle start, animated cover, swallowed wake, task reclamation and restoration of all four tiles")
            raise SystemExit(0)
        word("dvala 2")
        send("sendkey ret", 4)
        log = serial.read_text(errors="replace")
        assert "[dvala] running" in log, "idle timeout did not start the saver"
        first = shot("BL-009B-running")
        time.sleep(0.5)
        second = shot("BL-009B-moving")
        black = sum(first[i:i+3] == b"\0\0\0" for i in range(0, len(first), 3))
        assert black > len(first) // 3 * 0.97, "saver does not cover the screen"
        assert first != second, "starfield does not animate"
        assert any(first), "starfield is blank"
        send("sendkey x", 0.7)
        word("dvala off")
        send("sendkey ret", 0.6)
        word("echo awake")
        send("sendkey ret", 0.5)
        desktop = shot("BL-009B-awake")
        log = serial.read_text(errors="replace")
        assert "[dvala] stopped" in log, "saver task was not stopped"
        tid = re.search(r"\[dvala\] running task=(\d+)", log).group(1)
        assert "[sched] reaped task " + tid + " stack=" in log.split("[dvala] running task=", 1)[1], "saver task was not reaped"
        assert "[sh] awake\n" in log, "wake key leaked or focus was not restored"
        assert "[sh] unknown command: xdvala" not in log, "wake key leaked"
        assert desktop != second, "desktop was not restored"
        word("start test/mouse.elf")
        send("sendkey ret", 1)
        send("sendkey alt-tab", 0.5)
        send("sendkey alt-ret", 0.5)
        full = shot("BL-009B-general-fullscreen")
        assert full == bytes.fromhex("101418") * (len(full) // 3), "general full screen leaves a bar, title or pointer"
        send("sendkey alt-ret", 0.5)
        normal = shot("BL-009B-general-restored")
        assert normal != full, "full screen did not restore the tiled layout"
        send("sendkey alt-w", 0.5)
        word("dvala 2")
        send("sendkey ret", 3)
        send("mouse_move 8 0", 0.7)
        word("dvala off")
        send("sendkey ret", 0.5)
        word("echo mouseawake")
        send("sendkey ret", 0.5)
        log = serial.read_text(errors="replace")
        assert log.count("[dvala] running") == 2, "mouse wake case did not start a saver"
        assert log.count("[dvala] stopped") == 2, "mouse movement did not stop the saver"
        assert "[sh] mouseawake\n" in log, "mouse wake did not restore shell focus"
        word("dvala 2")
        send("sendkey ret")
        word("start test/mouse.elf")
        send("sendkey ret", 1)
        send("sendkey alt-tab")
        send("sendkey alt-ret", 3)
        send("mouse_button 1", 0.7)
        send("mouse_move 8 0", 0.4)
        held = shot("BL-009B-held-wake")
        assert held == bytes.fromhex("101418") * (len(held) // 3), "held waking button leaked or previous full screen was not restored"
        send("mouse_button 0")
        send("sendkey alt-w", 0.5)
        word("dvala off")
        send("sendkey ret", 0.5)
        log = serial.read_text(errors="replace")
        assert log.count("[dvala] running") == 3, "click wake case did not start a saver"
        assert log.count("[dvala] stopped") == 3, "click did not stop the saver"
        assert "KERNEL PANIC" not in log, "kernel panicked"
        (root / "build/evidence" / serial_name).write_text(log)
        print("PASS idle start, animated full cover, keyboard and mouse wake, held button suppression, task stop, focus restore and general full screen restore")
    finally:
        if serial.exists():
            (root / "build/evidence" / serial_name).write_bytes(serial.read_bytes())
        proc.terminate()
        proc.wait(timeout=5)
