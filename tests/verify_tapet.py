import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
evidence = root / 'build/evidence/BL-010B-evidence'
evidence.mkdir(parents=True, exist_ok=True)
control = os.environ.get('TAPET_RED', '')
assert control in ('', '1', 'pixels', 'lock'), 'unknown TAPET_RED control'
phase = {'': 'fixed', '1': 'red', 'pixels': 'red-pixels', 'lock': 'red-lock'}[control]
work = Path(tempfile.mkdtemp(prefix='tapet-'))
print(work, flush=True)
try:
    tree = work / 'moonshot'
    shutil.copytree(root, tree, ignore=shutil.ignore_patterns(
        '.git', '.*', 'release', 'company', 'out', 'build', 'isoroot',
        '*.iso', '*.img', '*.log', '*.sock', 'screenshots'))
    for name in ('c0-coff', 'gnista', 'utsikt'):
        (work / name).symlink_to(root.parent / name, target_is_directory=True)
    source = (root / 'programs/tapet/tapet.c0').read_text()
    if control == '1':
        source = source.replace('store64(buf + 16, 1);', 'store64(buf + 16, 0);')
    source = source.replace('int main() {', 'int tapet_main() {')
    source += '''
int main() {
    int rc = tapet_main();
    if (rc != 0) { return rc; }
    int n = readfile(argv(1), 0, 0);
    int b = alloc(n);
    readfile(argv(1), b, n);
    int sum = 0;
    int i = 0;
    for (i = 0; i < n; i += 1) { sum = (sum * 31 + load8(b + i)) & 2147483647; }
    if (sum == 381427311) { print("TAPET_HASH_OK\\n"); }
    return 0;
}
'''
    (tree / 'programs/tone.c0').write_text(source)
    with (evidence / (phase + '-build.log')).open('w') as log:
        subprocess.run(['bash', './build.sh'], cwd=tree, stdout=log, stderr=subprocess.STDOUT, check=True)
    boot = work / 'iso/boot'
    (boot / 'grub').mkdir(parents=True)
    shutil.copy(tree / 'build/moonshot.elf', boot / 'moonshot.elf')
    shutil.copy(tree / 'kernel/core/grub_test.cfg', boot / 'grub/grub.cfg')
    subprocess.run(['grub-mkrescue', '-o', str(work / 'boot.iso'), str(work / 'iso')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    serial = work / 'serial.log'
    proc = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(work / 'boot.iso'), '-display', 'none', '-serial', 'file:' + str(serial), '-m', '128', '-no-reboot', '-monitor', 'unix:' + str(work / 'mon') + ',server,nowait'])
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
            p = evidence / ((phase + '-' if control else '') + name + '.ppm')
            send('screendump ' + str(p), .5)
            return p.read_bytes().split(b'\n', 3)[3]
        line('root', .3)
        line('')
        data = struct.pack('<QQQ', 64, 48, 1)
        for y in range(48):
            for x in range(64):
                data += bytes((48 + (x+7)%80, 40+(y+7)%72, 24+((x+y+7)//16)%2*32, 0))
        checksum = 0
        for b in data:
            checksum = (checksum * 31 + b) & 2147483647
        for _ in range(2):
            line('start test/tone.elf picture.spr 7 64 48', 2)
        log = serial.read_text(errors='replace')
        assert log.count('TAPET_HASH_OK\n') == 2, 'fixed file hash or repeat determinism failed'
        line('write hylla.bg ' + ('absent.spr' if control == 'pixels' else 'picture.spr'))
        line('start hylla.elf', 3)
        send('sendkey alt-tab', 1)
        frame = shot('hylla')
        for x, y in ((900, 500), (920, 530), (960, 500)):
            sx, sy = (x-512)%64, y%48
            want = bytes((24+((sx+sy+7)//16)%2*32, 40+(sy+7)%72, 48+(sx+7)%80))
            assert frame[(y*1024+x)*3:(y*1024+x)*3+3] == want, ('hylla pixel', x, y)
        if control != 'lock':
            send('sendkey alt-l', 1)
        locked = shot('locked')
        time.sleep(1)
        locked2 = shot('locked-later')
        for x, y in ((900, 500), (920, 530), (960, 500)):
            offset = (y*1024+x)*3
            assert locked[offset:offset+3] != frame[offset:offset+3], 'wallpaper visible through lock'
            assert locked[offset:offset+3] == locked2[offset:offset+3], 'hylla repainted lock'
        assert 'PANIC' not in serial.read_text(errors='replace')
        print('PASS deterministic file hash, hylla pixels, lock coverage across frames', flush=True)
        sock.close()
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        if serial.exists():
            shutil.copy(serial, evidence / (phase + '-serial.log'))
    if not control:
        keys = []
        for text in ('root', '', 'start test/tone.elf picture.spr 7 64 48', 'write hylla.bg picture.spr', 'start hylla.elf'):
            keys += [{' ': 'spc', '.': 'dot', '/': 'slash'}.get(c, c) for c in text] + ['ret']
        keys += ['alt-tab', 'r']
        shutil.copy(tree / 'kernel/core/grub_test.cfg', tree / 'kernel/core/grub.cfg')
        env = dict(os.environ, SCREENSHOT_SETTLE='3')
        with (evidence / 'screenshot.log').open('w') as log:
            subprocess.run(['bash', 'tools/screenshot.sh', 'tapet', '4', *keys], cwd=tree, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        for p in (tree / 'screenshots').glob('*tapet*'):
            shutil.copy(p, evidence / p.name)
finally:
    shutil.rmtree(work)
