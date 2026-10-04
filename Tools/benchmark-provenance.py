#!/usr/bin/env python3
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
"""Refuse to benchmark a stale build and identify the exact WSurf source."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
paths = list((root / 'WSurf').rglob('*.swift')) + list((root / 'WSurfTests').rglob('*.swift'))
paths += [root / 'WSurf.xcodeproj/project.pbxproj', root / 'WSurf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved']
paths += [root / 'Tools' / name for name in ['benchmark-provenance.py', 'build-benchmark-adapter.sh', 'run-benchmark-adapter.sh']]
digest = hashlib.sha256()
for path in sorted(paths):
    digest.update(str(path.relative_to(root)).encode())
    digest.update(path.read_bytes())
metadata = {
    'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'source_sha256': digest.hexdigest(),
    'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True)),
}
record = Path(os.environ.get('WSURF_BENCHMARK_DERIVED_DATA', root / 'build/BenchmarkDD')) / 'benchmark-build.json'
if sys.argv[1] == 'write':
    record.write_text(json.dumps(metadata, indent=2))
elif sys.argv[1] == 'verify':
    if not record.exists() or json.loads(record.read_text())['source_sha256'] != metadata['source_sha256']:
        raise SystemExit('Benchmark build is stale. Run Tools/build-benchmark-adapter.sh.')
elif sys.argv[1] == 'hash':
    print(metadata['source_sha256'])
else:
    raise SystemExit('Expected write, verify, or hash')
