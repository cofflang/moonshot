#!/usr/bin/env python3
"""Exercise the evidence lifecycle without building or starting a guest."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

script = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).with_name('verify_execute_arguments.sh')
with tempfile.TemporaryDirectory(prefix='execute-cleanup-control.') as scratch:
    root = Path(scratch)
    binary = root / 'bin'
    binary.mkdir()
    stub = binary / 'python3'
    stub.write_text('#!' + sys.executable + '\n' + """
import os
from pathlib import Path
import sys
code = sys.stdin.read().split('base = evidence / "snapshot"', 1)[0]
exec(compile(code, '<evidence setup>', 'exec'))
Path(os.environ['CONTROL_PATH']).write_text(str(evidence))
sys.exit(int(os.environ['CONTROL_STATUS']))
""")
    stub.chmod(0o755)
    env = dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH'],
               TMPDIR=str(root), CONTROL_PATH=str(root / 'path'))
    env.pop('EXECUTE_EVIDENCE_DIR', None)
    failures = []
    for status in (0, 1):
        case = root / str(status)
        case.mkdir()
        result = subprocess.run(['bash', str(script)], env=dict(env, TMPDIR=str(case), CONTROL_STATUS=str(status)),
                                capture_output=True, text=True)
        saved = (root / 'path').read_text().strip()
        folders = list(case.glob('moonshot-execute-arguments.*'))
        if status == 0:
            ok = result.returncode == 0 and not folders
        else:
            ok = (result.returncode == 1 and len(folders) == 1 and
                  str(folders[0]) == saved and saved in result.stdout + result.stderr)
        print(f'{"PASS" if ok else "FAIL"} automatic evidence status {status}', flush=True)
        if not ok:
            failures.append(status)
    explicit = root / 'explicit'
    explicit.mkdir()
    sentinel = explicit / 'sentinel'
    sentinel.write_text('preserve')
    for status in (0, 1):
        result = subprocess.run(['bash', str(script)],
                                env=dict(env, CONTROL_STATUS=str(status), EXECUTE_EVIDENCE_DIR=str(explicit)),
                                capture_output=True, text=True)
        assert result.returncode == status and sentinel.read_text() == 'preserve'
    print('PASS explicit evidence preserved on success and failure')
    assert not failures, failures
