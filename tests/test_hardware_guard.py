#!/usr/bin/env python3
import argparse
import hashlib
from pathlib import Path
import socket
import subprocess
import tempfile
import shutil
import time

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--elf', type=Path, default=ROOT / 'build/moonshot.elf')
p.add_argument('--unguarded', action='store_true')
p.add_argument('--uefi', action='store_true')
p.add_argument('--evidence', type=Path, required=True)
a = p.parse_args()
a.evidence.mkdir(parents=True, exist_ok=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix='bl016c-') as td:
    tmp = Path(td)
    grub = tmp / 'iso/boot/grub'
    grub.mkdir(parents=True)
    (grub.parent / 'moonshot.elf').write_bytes(a.elf.read_bytes())
    (grub / 'grub.cfg').write_bytes((ROOT / ('kernel/core/grub.cfg' if a.uefi else 'kernel/core/grub_test.cfg')).read_bytes())
    firmware = []
    if a.uefi:
        shutil.copyfile('/usr/share/OVMF/x64/OVMF_VARS.4m.fd', tmp / 'vars.fd')
        firmware = ['-drive', 'if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/x64/OVMF_CODE.4m.fd', '-drive', 'if=pflash,format=raw,file=' + str(tmp / 'vars.fd')]
    subprocess.run(['grub-mkrescue', '-o', str(tmp / 'boot.iso'), str(tmp / 'iso')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def boot(name, disk, commands=()):
        log = a.evidence.resolve() / (name + '.serial')
        log.unlink(missing_ok=True)
        sock = tmp / 'monitor'
        sock.unlink(missing_ok=True)
        q = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(tmp / 'boot.iso'), '-boot', 'd', '-m', '128', '-display', 'none', '-no-reboot', '-serial', 'file:' + str(log), '-monitor', 'unix:' + str(sock) + ',server,nowait', '-drive', 'file=' + str(disk) + ',format=raw,if=ide,index=0'] + firmware)
        try:
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                if log.exists() and b'tick 40' in log.read_bytes():
                    break
                if q.poll() is not None:
                    raise AssertionError('QEMU exited during boot')
                time.sleep(.1)
            else:
                raise AssertionError('boot timeout')
            time.sleep(2)
            with socket.socket(socket.AF_UNIX) as s:
                s.connect(str(sock))
                s.settimeout(3)
                s.recv(4096)
                def line(text):
                    for c in text + '\n':
                        key = {' ': 'spc', '\n': 'ret', '.': 'dot', '/': 'slash', '-': 'minus'}.get(c, 'shift-' + c.lower() if c.isupper() else c)
                        s.sendall(('sendkey ' + key + '\n').encode())
                        time.sleep(.15)
                        s.recv(4096)
                    time.sleep(.7)
                if commands:
                    line('root')
                    line('')
                    time.sleep(1)
                    for command in commands:
                        line(command)
                s.sendall(b'quit\n')
            q.wait(timeout=10)
        finally:
            if q.poll() is None:
                q.terminate()
                try:
                    q.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    q.kill()
                    q.wait()
        return log.read_text(errors='replace')

    if a.uefi:
        disk = tmp / 'uefi.img'
        disk.write_bytes(bytes(10 * 1024 * 1024))
        before = digest(disk)
        log = boot('uefi', disk, ['besikta'])
        assert digest(disk) == before
        assert 'CPU - x86_64 vendor' in log
        assert 'Framebuffer - 1024x768' in log
        assert 'Memory map - base, bytes, type' in log
        assert 'KERNEL PANIC' not in log
        assert log.count('page fault:') == 1
        assert 'demand paging OK: fault recovered' in log
        print('UEFI boot, login, besikta and unchanged blank disk PASS', flush=True)
        raise SystemExit(0)

    for name, prefix in [('blank', bytes(512)), ('foreign', b'FOREIGN' + bytes(503) + b'\x55\xaa')]:
        disk = tmp / (name + '.img')
        disk.write_bytes(prefix + bytes(10 * 1024 * 1024 - 512))
        before = digest(disk)
        log = boot(name, disk, ['sync'])
        after = digest(disk)
        print(name, before, after, 'UNCHANGED' if before == after else 'CHANGED', flush=True)
        if a.unguarded:
            assert before != after, 'unfixed tree unexpectedly preserved disk'
        else:
            assert before == after, 'foreign disk modified'
            assert 'disk left untouched' in log
    if not a.unguarded:
        disk = tmp / 'create.img'
        disk.write_bytes(bytes(10 * 1024 * 1024))
        before = digest(disk)
        log = boot('wrong-confirmation', disk, ['sync create', 'wrong', 'sync'])
        assert digest(disk) == before, 'wrong confirmation modified disk'
        assert 'creation cancelled' in log
        log = boot('create', disk, ['sync create', 'CREATE MOONSHOT', 'make guard.txt', 'write guard.txt GuardWorks', 'sync', 'besikta'])
        assert disk.read_bytes()[:8] == b'JAKELBK\0'
        assert b'GuardWorks' in disk.read_bytes()
        assert 'disk created' in log
        log = boot('reboot', disk, ['echo --file guard.txt'])
        assert 'GuardWorks' in log
        assert b'boot.log' in disk.read_bytes()
        assert b'Boot log ready - F12 to view' in disk.read_bytes()
        print('wrong confirmation, explicit creation, file persistence and guarded boot.log PASS', flush=True)
print('PASS', flush=True)
