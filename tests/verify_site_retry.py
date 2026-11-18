import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = (ROOT / 'build.sh').read_text()
GUARD = BUILD.split('# BEGIN SITE GUARD\n')[1].split('# END SITE GUARD')[0]

with tempfile.TemporaryDirectory(prefix='site-home-') as home, tempfile.TemporaryDirectory(prefix='site-retry-', dir='/tmp') as temporary:
    os.environ['HOME'] = home
    work = Path(temporary)
    source = work / 'source'
    source.mkdir()
    (source / 'one').write_text('fixture')
    (source / 'two').write_text('fixture')
    (work / 'list').write_text('one\n')
    config = work / 'root'
    good = str(source) + '\n'

    def run(guard, body):
        return subprocess.run(['bash', '-eu', '-c', guard + '\n' + body], cwd=work,
                              capture_output=True, text=True)

    call = 'site_guard "" list root'
    cases = [('', '"${#roots[@]}" != 1'),
             (good + good, '"${#roots[@]}" != 1'),
             ('relative\n', '*) echo "site copy refuses a relative site folder"'),
             ('/tmp/../outside\n', '/|*/|*//*|*/.*|*[!a-zA-Z0-9_./-]*)')]
    for value, condition in cases:
        config.write_text(value)
        fixed = run(GUARD, call)
        assert fixed.returncode != 0 and 'refuses' in fixed.stderr, fixed
        if condition.startswith('"'):
            mutant = GUARD.replace('echo "site copy refuses an empty or multi-line root configuration" >&2', 'return 0')
        elif condition.startswith('*)'):
            mutant = GUARD.replace(condition, '*) return 0; echo "site copy refuses a relative site folder"')
        else:
            mutant = GUARD.replace('echo "site copy refuses a site folder outside the safe path pattern" >&2', 'return 0')
        assert run(mutant, call).returncode == 0
        print('PASS root configuration refusal and RED removed boundary', repr(value))
    config.unlink()
    (work / 'good').write_text(good)
    config.symlink_to(work / 'good')
    assert run(GUARD, call).returncode != 0
    mutant = GUARD.replace('[ -L "$config" ] || [ ! -f "$config" ]', 'false')
    assert run(mutant, call).returncode == 0
    print('PASS root configuration symlink refusal and RED removed boundary')
    config.unlink()
    config.write_text(good)
    gate = BUILD.split('site_guard "" "$HOME/.config/moonshot/site-files"')[2].split('site_args=()')[0]
    gate = 'site_guard "" list root' + gate
    body = call + '\nSITE_CHECKED=("${SITE_FILES[@]}")\nprintf "two\\n" > list\n' + gate
    result = run(GUARD, body)
    assert result.returncode != 0 and 'changed resolved subset' in result.stderr, result
    mutant = body.replace('[ "${SITE_FILES[*]}" != "${SITE_CHECKED[*]}" ]', 'false')
    assert run(GUARD, mutant).returncode == 0
    print('PASS changed resolved list refusal and RED disabled comparison')
    (work / 'list').write_text('one\n')
    body = call + '\nSITE_CHECKED=("${SITE_FILES[@]}")\nrm source/one\nmkfifo source/one\n' + gate
    result = run(GUARD, body)
    assert result.returncode != 0 and 'non-regular' in result.stderr, result
    print('PASS FIFO replacement refused at second guard')

from verify_site_followup import privacy
privacy()
