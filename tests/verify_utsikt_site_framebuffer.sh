#!/usr/bin/env bash
# Copyright (C) 2026 tavro
# Check the source-defined site through the browser and its real framebuffer.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
"$root/build.sh"
python3 - "$root" <<'PY'
from pathlib import Path
import re, socket, subprocess, sys, tempfile, time
root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='moonshot-site-fb.') as directory:
    work = Path(directory)
    boot = work/'iso/boot'
    (boot/'grub').mkdir(parents=True)
    (boot/'moonshot.elf').write_bytes((root/'build/moonshot.elf').read_bytes())
    (boot/'grub/grub.cfg').write_bytes((root/'kernel/core/grub_test.cfg').read_bytes())
    subprocess.run(['grub-mkrescue', '-o', str(work/'moonshot.iso'), str(work/'iso')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    proc = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(work/'moonshot.iso'), '-serial', 'file:'+str(work/'serial.log'), '-display', 'none', '-no-reboot', '-m', '128', '-monitor', 'unix:'+str(work/'monitor.sock')+',server,nowait'])
    try:
        time.sleep(3)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(str(work/'monitor.sock'))
        sock.recv(65536)
        def send(command, delay=.08):
            sock.sendall((command+'\n').encode())
            time.sleep(delay)
            sock.recv(65536)
        def keys(text):
            mapping = {' ':'spc', '.':'dot', '/':'slash'}
            for c in text:
                send('sendkey '+mapping.get(c,c))
        def shot(name):
            path = work/(name+'.ppm')
            send('screendump '+str(path), .4)
            data = path.read_bytes()
            match = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', data)
            assert match, 'PPM header'
            return int(match[1]), int(match[2]), data[match.end():]
        def pixel(frame,x,y):
            w,h,data=frame
            return tuple(data[(y*w+x)*3:(y*w+x+1)*3])
        def green(frame):
            w,h,data=frame
            points=[]
            for y in range(12,90):
                for x in range(w//2,w):
                    r,g,b=pixel(frame,x,y)
                    if 25 <= r <= 112 and 130 <= g <= 208 and 10 <= b <= 112:
                        points.append((x,y,(r,g,b)))
            assert len(points)>200, 'gradient heading is visible'
            assert len({c for x,y,c in points})>12, 'gradient has intermediate colours'
            return points
        keys('root'); send('sendkey ret'); send('sendkey ret',1)
        keys('start utsikt.elf test/site/index.html'); send('sendkey ret',3); send('sendkey alt-tab',1)
        first=shot('root-first'); time.sleep(.25); second=shot('root-second')
        green(first); green(second)
        assert pixel(second,800,300)==(17,17,17), 'linked dark background'
        assert not any(pixel(second,x,y)==(240,224,96) for y in range(90,125) for x in range(515,800)), 'mark has no yellow background'
        assert any(pixel(second,x,y)==(255,255,255) for y in range(80,125) for x in range(520,540)), 'main text has no 96 pixel inset'
        source=(root/'kernel/screen/punkt.c0').read_text()
        hi=source.split('int font_hi(int ch) {')[1].split('int font_lo(int ch) {')[0]
        lo=source.split('int font_lo(int ch) {')[1].split('// Draws one character')[0]
        codes=[229,228,246,197,196,214,233,8211,8230,8220,8221]
        offsets=[0,2,4,6,8,10,12,14,16,18,23]
        rows=[]
        for c in codes:
            pattern=r'if \(ch == '+str(c)+r'\) \{ return (0x[0-9A-Fa-f]+);'
            value=(int(re.search(pattern,hi)[1],16)<<32)|int(re.search(pattern,lo)[1],16)
            rows.append(value.to_bytes(8,'big'))
        found=False
        for y in range(108,150):
            x=520
            if all((pixel(second,x+off*8+col,y+row)==(255,255,255)) == bool(bits[row] & (128>>col)) for off,bits in zip(offsets,rows) for row in range(8) for col in range(8)):
                found=True
                break
        assert found, 'all eleven kernel glyphs match browser framebuffer'
        pos=[0,0]
        for _ in range(12): send('mouse_move -100 -100',.03)
        def move(x,y):
            while pos!=[x,y]:
                dx=max(-100,min(100,x-pos[0])); dy=max(-100,min(100,y-pos[1]))
                send('mouse_move %d %d'%(dx,dy),.03)
                pos[0]+=dx;pos[1]+=dy
        def click(x,y):
            move(x,y);send('mouse_button 1',.35);send('mouse_button 0',2)
        for label,x in [('resume',540),('blog',580),('now',610),('explore',650)]:
            click(x,72)
            page=shot(label)
            print('captured',label,flush=True)
            points=green(page)
            assert max(x for x,y,c in points)-min(x for x,y,c in points) != max(x for x,y,c in green(first))-min(x for x,y,c in green(first)), 'destination page differs'
            assert pixel(page,800,300)==(17,17,17), 'destination sheet resolved'
            linkcolor=(0,64,192) if label in ('resume','blog') else (255,255,255)
            linkrows=[y for y in range(65,150) if all(pixel(page,x,y)==linkcolor for x in range(522,600))]
            assert linkrows, 'return link underline located'
            print('return row',linkrows,flush=True)
            click(530,linkrows[0]-2)
            returned=shot(label+'-return')
            assert green(returned) == green(first), 'relative return link restores root heading'
            send('sendkey backspace',1)
            send('sendkey backspace',1)
            rootframe=shot(label+'-back')
            green(rootframe)
        send('sendkey alt-w',.3)
        sock.close()
        print('PASS fixture pixels, glyphs, four menu destinations and history')
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill();proc.wait()
PY
