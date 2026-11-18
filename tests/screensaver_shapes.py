import pathlib
import socket
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
(root / "build/evidence/BL-020-evidence").mkdir(parents=True, exist_ok=True)
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
            path = root / "build/evidence/BL-020-evidence" / (name + ".ppm")
            send("screendump " + str(path), 0.3)
            return path.read_bytes().split(b"\n", 3)[3]
        word("root")
        send("sendkey ret")
        send("sendkey ret", 1)
        assert "[dvala] running" not in serial.read_text(errors="replace"), "saver enabled itself at boot"
        for rejected in ["pipes", "starfield", "drift1", "drift2", "drift3", "unknown"]:
            before = len(serial.read_text(errors="replace"))
            word("dvala " + rejected)
            send("sendkey ret", .3)
            response = serial.read_text(errors="replace")[before:]
            assert "dvala [on | off | seconds 1..86400]" in response, response
            assert "dvala mode " not in response, "removed mode accepted"
        word("dvala 2")
        send("sendkey ret", 4)
        log = serial.read_text(errors="replace")
        assert "[dvala] running" in log, "starfield did not start after timeout"
        first = shot("starfield-first")
        time.sleep(0.5)
        second = shot("starfield-moving")
        assert first != second and any(first), "starfield does not animate"
        colours = {first[i:i+3] for i in range(0, len(first), 3)}
        assert len(colours) >= 4, "starfield lacks shaded geometry"
        assert all(c[0] == c[1] == c[2] for c in colours), "starfield contains coloured pixels"
        assert b"\0\0\0" in colours, "starfield lacks black background"
        send("sendkey x", 0.5)
        word("dvala off")
        send("sendkey ret", 0.3)
        word("echo awake")
        send("sendkey ret", 0.3)
        log = serial.read_text(errors="replace")
        assert "unknown command: xdvala" not in log, "wake leaked"
        assert "[sh] awake\n" in log, "shell focus lost"
        print("PASS starfield timeout, shaded animated frames and wake")
        log = serial.read_text(errors="replace")
        assert log.count("[dvala] stopped") == 1, "savers did not stop"
        assert "KERNEL PANIC" not in log, "kernel panicked"
    finally:
        if serial.exists():
            (root / "build/evidence/BL-020-evidence/dvala.serial").write_bytes(serial.read_bytes())
        proc.terminate()
        proc.wait(timeout=5)
