#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B tests/preservation_der/test_contract.py -v
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat SideStore/Core/Operations/PipelineOperations/PreservedProfileDecoder.swift tests/preservation_der/SwiftCases.swift > "$work/main.swift"
swiftc "$work/main.swift" -o "$work/parser"
if "$work/parser" tests/preservation_der/swift-cases.json | tee "$work/parser.json"; then
  : # Only the original exact-source executable can reach receipt validation below.
else
  primary_status=$?
  # Diagnostic execution cannot convert the primary failure into success.
  # Only fixed synthetic baseline bytes are used; no public or user profiles.
  if python3 -B tests/preservation_der/generate_failure_diagnostic.py --output "$work/diagnostic" &&
     swiftc "$work/diagnostic/main.swift" -o "$work/diagnostic/probe"; then
    "$work/diagnostic/probe" "$work/diagnostic/baseline.json" || true
  fi
  exit "$primary_status"
fi
python3 - "$work/parser.json" <<'PY'
import json,pathlib,sys
expected=json.loads(pathlib.Path('tests/preservation_der/swift-cases.json').read_text())
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert len(lines)==1
r=json.loads(lines[0])
assert set(r)=={'schema','status','cases','cms_verified','device_executed'}
assert r['schema']=='preservation-der-parser-v1' and r['status']=='PASS'
assert r['cms_verified'] is False and r['device_executed'] is False
assert r['cases']==[x['name'] for x in expected['cases']] and len(r['cases'])==59
assert r['cases']==json.loads(pathlib.Path('tests/preservation_der/expected-cases.json').read_text())['parser']
PY
