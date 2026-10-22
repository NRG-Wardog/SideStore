#!/bin/bash
set -euo pipefail
# All input roots are explicit; no dependency on checkout location or shell cwd.
candidate=""; baseline=""; output=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --candidate-root) candidate="$2"; shift 2 ;;
        --baseline-root) baseline="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) echo "Unknown argument" >&2; exit 2 ;;
    esac
done
[[ -n "$candidate" && -n "$baseline" && -n "$output" ]] || {
    echo "Required: --candidate-root ROOT --baseline-root ROOT --output DIRECTORY" >&2; exit 2;
}
[[ "$(uname -s)" == Darwin ]] || {
    echo "Matching macOS Swift/Security/CryptoKit toolchain required; runtime NOT RUN" >&2; exit 2;
}
package="$candidate/SideStore/.ci/remote-identity-reuse"
python3 "$package/generate_fixture.py" --candidate-root "$candidate" --baseline-root "$baseline" --output "$output"
python3 - "$candidate" "$baseline" "$output" <<'PY'
import hashlib, json, pathlib, sys
candidate, baseline, output = map(pathlib.Path, sys.argv[1:])
evidence = json.loads((output / 'source-evidence.json').read_text())
expected = {'CandidateCore.swift', 'BoundaryDoubles.swift', 'CoreCases.swift',
            'CandidateRuntime.swift', 'RuntimeDoubles.swift', 'RuntimeCases.swift'}
assert set(evidence['outputs_sha256']) == expected
for root, key in [(candidate, 'inputs_sha256'), (baseline, 'baseline_inputs_sha256'),
                  (candidate, 'support_inputs_sha256'), (output, 'outputs_sha256')]:
    for name, digest in evidence[key].items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, name
PY
xcrun swiftc -swift-version 5 -parse-as-library \
    "$output/CandidateCore.swift" "$output/BoundaryDoubles.swift" "$output/CoreCases.swift" \
    "$output/CandidateRuntime.swift" "$output/RuntimeDoubles.swift" "$output/RuntimeCases.swift" \
    -framework Security -o "$output/remote-identity-regression"
"$output/remote-identity-regression" --cases-output "$output/cases.json" | tee "$output/runtime.log"
python3 - "$output" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
evidence = json.loads((root / 'source-evidence.json').read_text())
for name, expected in evidence['outputs_sha256'].items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
lines = (root / 'runtime.log').read_text().splitlines()
cases = [line.removeprefix('PASS ') for line in lines if line.startswith('PASS ')]
assert cases and len(cases) == len(set(cases))
assert sorted(cases) == sorted(evidence['expected_case_names'])
assert lines[-1] == 'REMOTE_IDENTITY_REUSE_RUNTIME_PASS cases=' + str(len(cases))
export = json.loads((root / 'cases.json').read_text())
assert export['schema'] == 'remote-identity-reuse-cases-v1' and export['status'] == 'pass'
assert export['cases'] == cases and export['case_count'] == len(cases)
assert export['fake_only'] is True and export['native_keychain_executed'] is False
assert export['native_provider_executed'] is False and export['network_executed'] is False
receipt = {'schema': 'remote-identity-reuse-runtime-v1', 'status': 'PASS',
           'case_names': cases, 'case_count': len(cases),
           'source_evidence_sha256': hashlib.sha256((root / 'source-evidence.json').read_bytes()).hexdigest(),
           'network_executed': False, 'native_keychain_executed': False, 'native_provider_executed': False,
           'limits': ['Synthetic account/store boundaries; no live authentication, provider, device or native storage.']}
(root / 'runtime-evidence.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
