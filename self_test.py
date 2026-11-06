"""Safe smoke test that touches only a new temporary fixture directory."""
import json
import os
import shutil
from pathlib import Path
import tempfile


def run(output):
    from tree_io import extended, verify, handle_request
    result = {'passed': False, 'checks': []}
    try:
        Path(output).resolve().parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='codex-migrator-selftest-', dir=Path(output).resolve().parent) as directory:
            root = Path(directory)
            left, right = root / 'source', root / 'destination'
            relative = Path(*(['nested-package-directory'] * 10)) / 'Unicode-测试.txt'
            for base in (left, right):
                file = base / relative
                os.makedirs(extended(file.parent))
                Path(extended(file)).write_bytes(b'original contents')
                (base / 'empty.guard').write_bytes(b'')
            assert len(str(left / relative)) > 260
            checked = verify(str(left), str(right))
            assert checked['files'] == 2
            result['checks'].append('Unicode and >260-character path verification')
            Path(extended(right / relative)).write_bytes(b'modified contents')
            try:
                verify(str(left), str(right))
            except ValueError:
                result['checks'].append('Same-size corruption is rejected')
            else:
                raise AssertionError('Corruption was accepted')
            request = root / 'request.json'
            response = root / 'response.json'
            request.write_text(json.dumps({'operation': 'verify', 'paths': [str(left), str(left)], 'result': str(response)}), encoding='utf-8-sig')
            assert handle_request(str(request)) == 0
            assert json.loads(response.read_text(encoding='utf-8'))['event'] == 'result'
            result['checks'].append('UTF-8 BOM request and JSON result')
            shutil.rmtree(extended(root))
        result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
    Path(output).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    return 0 if result['passed'] else 1
