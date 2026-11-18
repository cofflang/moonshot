#!/usr/bin/env python3
"""Replay preempted serial markers through the execute test oracle."""
import ast
from pathlib import Path
import re
import sys
import tempfile
from types import SimpleNamespace

script = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).with_name('verify_execute_arguments.sh')
code = script.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
tree = ast.parse(code)
functions = ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef)
                            and n.name in ('clean', 'wait', 'run', 'records',
                                           'input_bytes', 'pipeline')], type_ignores=[])
with tempfile.TemporaryDirectory(prefix='execute-serial-control.') as scratch:
    state = {'data': b'', 'clock': 0}
    def sleep(seconds):
        state['clock'] += seconds
    env = dict(re=re, time=SimpleNamespace(monotonic=lambda: state['clock'], sleep=sleep),
               evidence=Path(scratch), counter=0, qemu=SimpleNamespace(poll=lambda: None),
               read=lambda: state['data'])
    exec(compile(functions, str(script), 'exec'), env)
    marker = b'[sh] started task '
    exit_marker = b'[syscall] exit code=73\n'
    failures = []
    for label, noise in [('scheduler', b'[sched] -> task 4 (counter=0)\n'),
                         ('timer', b'tick 8400\n'), ('keyboard', b'key scancode 156\n')]:
        for target in ('start', 'exit'):
            for offset in (2, 10):
                state['data'] = b''
                state['clock'] = 0
                def line(text):
                    start = marker
                    end = exit_marker
                    if target == 'start':
                        start = marker[:offset] + noise + marker[offset:]
                    else:
                        end = exit_marker[:offset] + noise + exit_marker[offset:]
                    state['data'] = start + b'0\n[sh] prompt\n' + end
                env['line'] = line
                try:
                    data = env['run']('execute old.c0', (marker, exit_marker))
                    assert marker in data and exit_marker in data
                except AssertionError as error:
                    failures.append((label, target, offset, str(error)))
    state['data'] = b'guest produced no success marker\n'
    state['clock'] = 0
    try:
        env['wait'](exit_marker, timeout=.2)
    except AssertionError:
        print('PASS missing marker still fails')
    else:
        raise AssertionError('missing marker accepted')
    for failure in failures:
        print('FAIL', failure)
    assert not failures, failures
    print('PASS preempted markers for scheduler, timer and keyboard serial output')
    captured = (Path(__file__).parent / 'fixtures/execute_arguments_interleaved.txt').read_bytes()
    env['full'] = True
    def replay(data):
        state['data'] = b''
        state['clock'] = 0
        def line(text):
            state['data'] = data
        env['line'] = line
        return env['pipeline']('hello.c0', nonroot=True)
    replay(captured)
    print('PASS captured suite failure with interleaved shell mirror')
    for label, data in (
        ('missing final spawn', re.sub(rb'^\[ea\] spawn\|86\|1\|[^\n]*\n', b'', captured, flags=re.M)),
        ('wrong final argv', captured.replace(b'|1|104,101,108,108,111,46,101,108,102,|',
                                             b'|1|105,101,108,108,111,46,101,108,102,|')),
        ('missing exit', captured.replace(b'[syscall] exit code=7\n', b'')),
        ('failed compiler', captured.replace(b'how=1 result=0', b'how=1 result=1', 1)),
    ):
        assert data != captured, label
        try:
            replay(data)
        except AssertionError:
            print('PASS rejected', label)
        else:
            raise AssertionError('accepted ' + label)
