#!/usr/bin/env python3
# Copyright (C) 2026 tavro
# SPDX-License-Identifier GPL-3.0-or-later
"""Change files between jakel_sync's two passes, reboot, and check every file."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'out/sync-layout'
out.mkdir(parents=True, exist_ok=True)
# Built from a copy of the tree, as tests/users.py does.
scratch = pathlib.Path(tempfile.mkdtemp(prefix='moonshot-sync-layout.'))
tree = scratch / 'moonshot'
tree.mkdir()
for name in ['kernel', 'programs', 'tools', 'tests']:
    shutil.copytree(root / name, tree / name, symlinks=True)
for name in ['build.sh', 'toolchain.sha256']:
    shutil.copy2(root / name, tree / name)
for sibling in ['c0-coff', 'gnista', 'utsikt']:
    if (root.parent / sibling).exists():
        (scratch / sibling).symlink_to(root.parent / sibling)
knekt = tree / 'kernel/core/knekt.c0'
original = knekt.read_bytes()
marker = b'    boot_log_persist();\n'
assert original.count(marker) == 1
fixture = (root / 'tests/fixtures/sync_layout.c0').read_bytes()
try:
    knekt.write_bytes(original.replace(marker, marker + b'    if (boot_test) { sync_layout_probe(); }\n') +
                      fixture)
    with (out / 'build.log').open('w') as log:
        # A debug build, the only kind with the sync pause hook.
        subprocess.run([str(tree / 'build.sh')], cwd=tree, stdout=log,
                       stderr=subprocess.STDOUT, check=True,
                       env=dict(os.environ, MOONSHOT_DEBUG='1'))
    shutil.copyfile(tree / 'build/moonshot.elf', out / 'moonshot.elf')
finally:
    shutil.rmtree(scratch)
iso = out / 'iso'
(iso / 'boot/grub').mkdir(parents=True, exist_ok=True)
shutil.copyfile(out / 'moonshot.elf', iso / 'boot/moonshot.elf')
shutil.copyfile(root / 'kernel/core/grub_test.cfg', iso / 'boot/grub/grub.cfg')
with (out / 'grub.log').open('w') as log:
    subprocess.run(['grub-mkrescue', '-o', str(out / 'test.iso'), str(iso)],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
disk = out / 'disk.img'
with disk.open('wb') as f:
    f.write(b'JAKELBK\0')
    f.truncate(512 * 20480)
def boot(name, marker):
    serial = out / name
    serial.write_bytes(b'')
    q = subprocess.Popen(['qemu-system-x86_64', '-cdrom', str(out / 'test.iso'),
                          '-serial', 'file:' + str(serial), '-display', 'none',
                          '-no-reboot', '-m', '128',
                          '-drive', 'file=' + str(disk) + ',format=raw,if=ide,index=0,media=disk'])
    try:
        end = time.monotonic() + 120
        while time.monotonic() < end and q.poll() is None:
            if marker in serial.read_bytes():
                break
            time.sleep(.1)
    finally:
        q.terminate()
        try:
            q.wait(timeout=5)
        except subprocess.TimeoutExpired:
            q.kill(); q.wait()
    return [line for line in serial.read_text(errors='replace').splitlines()
            if line.startswith('[sync-test]')]
first = boot('first.log', b'[sync-test] WROTE')
print('\n'.join(first))
assert first and first[-1] == '[sync-test] WROTE 0', 'the save did not finish'
second = boot('second.log', b'[sync-test] DONE')
print('\n'.join(second))
assert second and second[-1] == '[sync-test] DONE', 'the reload did not finish'
assert not any('FAIL' in line for line in first + second), 'sync layout'
print('PASS files changed during sync stay inside their own sectors')
