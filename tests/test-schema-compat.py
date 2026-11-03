import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

launcher = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'ccp'
mock = r'''
import os, pathlib, sqlite3, stat, sys
db = pathlib.Path(os.environ.get('CC_SWITCH_CONFIG_DIR', os.environ['HOME'] + '/.cc-switch')) / 'cc-switch.db'
schema = sqlite3.connect(db).execute('PRAGMA user_version').fetchone()[0]
limit = int(os.environ['TEST_LIMIT'])
if os.environ.get('TEST_ERROR'):
    sys.exit('unrecognized database failure')
if schema > limit:
    sys.exit('数据库错误: 最高支持数据库版本: ' + str(limit))
if '/state/' in str(db):
    assert stat.S_IMODE(db.stat().st_mode) == 0o600
    assert stat.S_IMODE(db.parent.stat().st_mode) == 0o700
    if os.environ.get('TEST_SNAPSHOT_ERROR'):
        sys.exit('snapshot incompatible')
if sys.argv[1:3] == ['provider', 'list']:
    print('DeepSeek')
elif sys.argv[1:3] == ['start', 'claude']:
    assert '--dry-run' in sys.argv
    assert sys.argv[3] == 'deepseek-id'
    print('--settings /test/settings.json')
else:
    sys.exit('unexpected CLI command')
'''

def run(schema, limit, check=False, error=False, snapshot_error=False):
    with tempfile.TemporaryDirectory() as temp:
        home = Path(temp)
        db = home / '.cc-switch/cc-switch.db'
        db.parent.mkdir()
        with sqlite3.connect(db) as conn:
            conn.execute(f'PRAGMA user_version={schema}')
            conn.execute('CREATE TABLE providers (id TEXT, name TEXT, app_type TEXT, sort_index INTEGER)')
            conn.execute("INSERT INTO providers VALUES ('deepseek-id', 'DeepSeek', 'claude', 0)")
        original = db.read_bytes()
        binary = home / 'bin/cc-switch'
        binary.parent.mkdir()
        binary.write_text('#!' + sys.executable + '\n' + mock)
        binary.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('CCP_', 'CC_SWITCH_'))}
        env.update(HOME=temp, PATH=str(binary.parent) + ':' + env['PATH'],
                   TEST_LIMIT=str(limit), CCP_USAGE_REFRESH='0')
        if error:
            env['TEST_ERROR'] = '1'
        if snapshot_error:
            env['TEST_SNAPSHOT_ERROR'] = '1'
        result = subprocess.run(['/bin/bash', str(launcher)] + (['--check'] if check else ['-n', 'DeepSeek']),
                                env=env, text=True, capture_output=True)
        assert db.read_bytes() == original, 'live database changed'
        assert not list((home / '.local/state/ccp').glob('*compat.*')), 'snapshot leaked'
        if error or snapshot_error:
            assert result.returncode != 0, result.stdout
            assert 'environment OK' not in result.stdout
        else:
            assert result.returncode == 0, result.stderr
            assert ('environment OK' if check else '--settings') in result.stdout
            assert ('snapshot' in result.stderr) == (schema > limit), result.stderr

for schema, limit in [(24, 22), (27, 25), (22, 22), (21, 22)]:
    run(schema, limit)
    run(schema, limit, check=True)
for check in (False, True):
    run(24, 22, check=check, error=True)
    run(24, 22, check=check, snapshot_error=True)
print('PASS: 12 cases; dynamic limits, check, failures, permissions, cleanup, live DB unchanged')
