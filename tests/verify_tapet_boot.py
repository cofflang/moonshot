import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
evidence = Path(os.environ.get('TAPET_BOOT_EVIDENCE', root / 'build/evidence/BL-010B-evidence'))
evidence.mkdir(parents=True, exist_ok=True)
phase = os.environ.get('TAPET_BOOT_PHASE', 'boot-fixed')
assert phase in ('boot-red', 'boot-fixed')
work = Path(tempfile.mkdtemp(prefix='tapet-'))
print(work, flush=True)
try:
    tree = work / 'moonshot'
    shutil.copytree(root, tree, ignore=shutil.ignore_patterns(
        '.git', '.*', 'release', 'company', 'out', 'build', 'isoroot',
        '*.iso', '*.img', '*.log', '*.sock', 'screenshots'))
    for name in ('c0-coff', 'gnista', 'utsikt'):
        (work / name).symlink_to(root.parent / name, target_is_directory=True)
    if os.environ.get('TAPET_BOOT_BREAK_WALLPAPER') == '1':
        p = tree / 'programs/hylla/hylla.c0'
        source = p.read_text()
        assert source.count('if (!bg_img) { return; }') == 1
        p.write_text(source.replace('if (!bg_img) { return; }', 'return;'))
    if phase == 'boot-red':
        p = tree / 'kernel/core/kmain.c0'
        p.write_text(p.read_text().replace('embed tapet_elf "../../build/tapet.elf";', ''))
        p = tree / 'kernel/files/jakel.c0'
        p.write_text(p.read_text().replace('jakel_seed_file(0, "tapet.elf", tapet_elf, tapet_elf_size);', ''))
    with (evidence / (phase + '-build.log')).open('w') as log:
        subprocess.run(['bash', './build.sh'], cwd=tree, stdout=log, stderr=subprocess.STDOUT, check=True)
    boot = work / 'iso/boot'
    (boot / 'grub').mkdir(parents=True)
    shutil.copy(tree / 'build/moonshot.elf', boot / 'moonshot.elf')
    shutil.copy(tree / 'kernel/core/grub.cfg', boot / 'grub/grub.cfg')
    subprocess.run(['grub-mkrescue', '-o', str(work / 'boot.iso'), str(work / 'iso')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    serial = work / 'serial.log'
    disk = work / 'disk.img'
    with disk.open('wb') as image:
        image.truncate(512 * 20480)
        image.write(b'JAKELBK\0')
    proc = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(work / 'boot.iso'), '-display', 'none', '-serial', 'file:' + str(serial), '-m', '128', '-no-reboot', '-drive', 'file=' + str(disk) + ',format=raw,if=ide,index=0,media=disk', '-monitor', 'unix:' + str(work / 'mon') + ',server,nowait'])
    try:
        time.sleep(4)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(4)
        sock.connect(str(work / 'mon'))
        sock.recv(65536)
        def send(cmd, delay=.12):
            sock.sendall((cmd + '\n').encode())
            time.sleep(delay)
            sock.recv(65536)
        def line(text, delay=1):
            mapping = {' ': 'spc', '.': 'dot', '/': 'slash'}
            for c in text:
                send('sendkey ' + mapping.get(c, c))
            send('sendkey ret', delay)
        def shot(name):
            p = evidence / (phase + '-' + name + '.ppm')
            send('screendump ' + str(p), .5)
            return p.read_bytes().split(b'\n', 3)[3]
        line('root', .3)
        line('')
        line('start tapet.elf picture.spr 7 64 48', 2)
        line('write hylla.bg ' + 'picture.spr')
        deadline = time.monotonic() + 60
        matches = 0
        attempt = 0
        while time.monotonic() < deadline:
            send('sendkey alt-tab', .3)
            send('sendkey alt-m', .3)
            send('sendkey r', .5)
            # A maximized tavla starts below its 8 pixel title strip.
            # Require the same three RGB samples in the wallpaper coordinates.
            ready_until = min(deadline, time.monotonic() + 3)
            while time.monotonic() < ready_until:
                frame = shot('hylla')
                matches = 0
                for x, y in ((400, 700), (420, 730), (460, 700)):
                    sx, sy = x%64, y%48
                    want = bytes((24+((sx+sy+7)//16)%2*32, 40+(sy+7)%72, 48+(sx+7)%80))
                    offset = ((y+8)*1024+x)*3
                    matches += frame[offset:offset+3] == want
                print('wallpaper candidate', attempt, 'matches', matches, flush=True)
                if matches == 3:
                    break
            if matches == 3:
                break
            send('sendkey alt-m', .3)
            attempt += 1
        assert matches == 3, ('normal boot hylla pixels', matches)
        assert 'PANIC' not in serial.read_text(errors='replace')
        print('PASS normal boot starts standalone tapet and hylla draws its pixels', flush=True)
        sock.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        if serial.exists():
            shutil.copy(serial, evidence / (phase + '-serial.log'))

finally:
    shutil.rmtree(work)
