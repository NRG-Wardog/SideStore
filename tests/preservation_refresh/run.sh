#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 tests/preservation_refresh/generate_fixture.py --output "$work"
swiftc "$work/Policy.swift" "$work/main.swift" -o "$work/policy"
"$work/policy" | tee "$work/policy.log"
swiftc -parse-as-library "$work/Integration.swift" -o "$work/integration"
"$work/integration" | tee "$work/integration.log"
python3 - "$work" <<'PYVERIFY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
expected=json.loads(pathlib.Path('tests/preservation_refresh/expected-cases.json').read_text())
for name in ['policy', 'integration']:
    lines=(root/(name+'.log')).read_text().splitlines()
    assert len(lines)==1, 'Unexpected native output: '+name
    result=json.loads(lines[0])
    assert result['schema']=='preservation-refresh-'+name+'-v1'
    assert result['status']=='PASS' and result['device_executed'] is False
    assert result['cases']==expected[name], 'Missing, reordered or extra native cases: '+name
PYVERIFY
