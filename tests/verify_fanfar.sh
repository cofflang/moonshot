#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
./build.sh
python3 - <<'PY'
import array, math, pathlib, socket, subprocess, tempfile, time, struct, wave
root = pathlib.Path.cwd()
(root / "build/evidence/BL-019-evidence").mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='fanfar-') as tmp:
    p = pathlib.Path(tmp)
    boot = p / 'iso/boot'
    (boot / 'grub').mkdir(parents=True)
    (boot / 'moonshot.elf').write_bytes((root / 'build/moonshot.elf').read_bytes())
    (boot / 'grub/grub.cfg').write_bytes((root / 'kernel/core/grub.cfg').read_bytes())
    subprocess.run(['grub-mkrescue', '-o', str(p/'boot.iso'), str(p/'iso')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(p/'disk', 'wb') as f:
        f.truncate(10485760)
    q = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(p/'boot.iso'), '-drive', f'file={p}/disk,format=raw,if=ide', '-serial', f'file:{p}/serial', '-display', 'none', '-no-reboot', '-m', '128', '-audiodev', f'wav,id=snd,path={p}/sound.wav', '-device', 'sb16,audiodev=snd', '-monitor', f'unix:{p}/monitor,server,nowait'])
    try:
        time.sleep(5)
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(str(p/'monitor'))
            s.recv(65536)
            for key in ['r', 'o', 'o', 't', 'ret', 'ret']:
                s.sendall(f'sendkey {key}\n'.encode())
                time.sleep(.25)
                s.recv(65536)
            time.sleep(16)
    finally:
        q.terminate()
        q.wait(timeout=10)
    log = (p/'serial').read_text()
    (root/'build/evidence/BL-019-evidence/fanfar.serial').write_text(log)
    assert 'PANIC' not in log, log
    assert '[raket] autostart fanfar task=' in log, 'missing fanfar login launch'
    assert log.count('[fanfar] render_ticks=') == 1, 'expected one login sound'
    assert '[fanfar] sketch=' not in log, 'sketch selection remains'
    assert '[fanfar] done' in log, 'fanfar did not drain and exit'
    data = (p/'sound.wav').read_bytes()
    assert data[:4] == b'RIFF' and data[36:40] == b'data', 'unexpected QEMU wav header'
    channels, rate = struct.unpack('<HI', data[22:28])
    assert struct.unpack('<H', data[34:36])[0] == 16
    samples = array.array('h', data[44:len(data) - (len(data)-44) % (channels * 2)])
    with wave.open(str(root/'build/evidence/BL-019-evidence/fanfar.wav'), 'wb') as recording:
        recording.setnchannels(channels)
        recording.setsampwidth(2)
        recording.setframerate(rate)
        recording.writeframes(samples.tobytes())
    active = [i//channels for i, v in enumerate(samples) if abs(v) > 256]
    assert active, 'silent recording'
    duration = (active[-1]-active[0])/rate
    assert 1.8 < duration < 2.2, f'unexpected audition span {duration}'
    mono = samples[::channels]
    for offset, frequency in [(0.10, 523.25), (0.35, 659.25), (0.60, 783.99), (1.2, 1046.5)]:
        start = active[0] + int(offset * rate)
        chunk = mono[start:start + int(.08 * rate)]
        def power(frequency):
            return abs(sum(value * complex(math.cos(2 * math.pi * frequency * i / rate),
                                           math.sin(2 * math.pi * frequency * i / rate))
                           for i, value in enumerate(chunk)))
        measured = max(range(450, 1150, 5), key=power)
        assert abs(measured - frequency) < 45, (offset, measured, frequency)
    assert max(abs(v) for v in samples) < 32767, 'clipped output'
    print(f'PASS fanfar login sound, non-silence span {duration:.2f}s, no clipping, drained')
PY
