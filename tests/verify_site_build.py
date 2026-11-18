import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--case', choices=('skips', 'disk'), required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='site-home-') as home_fixture, tempfile.TemporaryDirectory(prefix='site-build-', dir='/tmp') as temporary:
    work = Path(temporary)
    tree = work / 'moonshot'
    shutil.copytree(root, tree, ignore=shutil.ignore_patterns(
        '.git', '.*', 'release', 'company', 'out', 'build', 'isoroot',
        '*.iso', '*.img', '*.log', '*.sock', 'screenshots'))
    for name in ('c0-coff', 'gnista', 'utsikt'):
        (work / name).symlink_to(root.parent / name, target_is_directory=True)
    source = work / 'source'
    source.mkdir()
    home = Path(home_fixture)
    private = home / '.config/moonshot'
    private.mkdir(parents=True)
    (private / 'site-root').write_text(str(source) + '\n')
    scratch = work / 'tmp'
    scratch.mkdir()
    env = dict(os.environ, TMPDIR=str(scratch), HOME=str(home))

    def build(label):
        result = subprocess.run(['bash', './build.sh'], cwd=tree, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True)
        assert result.returncode == 0, label + '\n' + result.stdout
        disk = Path((tree / 'build/site-disk.path').read_text().strip())
        assert disk.is_file(), label + ' disk missing'
        assert b'site\0' not in disk.read_bytes(), label + ' unexpected /site'
        return result.stdout, disk

    if args.case == 'skips':
        output, _ = build('missing list')
        assert 'site subset list absent, skipping /site' in output, output
        print('PASS copy without subset list builds without /site', flush=True)
        source.rmdir()
        (private / 'site-files').write_text('file.html\n')
        output, _ = build('missing source')
        assert 'site source folder absent, skipping /site' in output, output
        print('PASS copy without source builds without /site', flush=True)
        (private / 'site-root').unlink()
        output, _ = build('missing root configuration')
        assert 'site folder configuration absent, skipping /site' in output, output
        print('PASS copy without private root configuration builds without /site', flush=True)
    else:
        source.rmdir()
        _, first = build('first disk')
        _, second = build('second disk')
        assert first == second == tree / 'build/site-disk.img', (first, second)
        assert not list(scratch.glob('moonshot-site.*')), 'private temporary disk retained'
        print('PASS repeated builds replace one build disk and retain no temporary folders', flush=True)
