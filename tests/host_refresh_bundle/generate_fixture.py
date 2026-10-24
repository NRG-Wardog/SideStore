"""Compile exact production preparation + selector/defer with inert SDK boundaries.

The actual AppBundleFingerprint is included unchanged, including CryptoKit and
all filesystem checks. iOS/SideSign decoding is a synthetic boundary double;
this suite makes no claim of live signing/profile validity or device success.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import test_contract


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate-root', '--repo', type=Path, required=True)
    parser.add_argument('--output', '--out', type=Path, required=True)
    parser.add_argument('--fingerprint-source', type=Path)
    args = parser.parse_args()
    root, out = args.candidate_root.resolve(), args.output.resolve()
    assertions = test_contract.validate(root)
    here = root / 'tests/host_refresh_bundle'
    runner = root / 'SideStore/Core/Operations/PipelineRunner.swift'
    fingerprint = args.fingerprint_source or root / 'SideStore/Utils/common/AppBundleFingerprint.swift'
    inputs = [runner, fingerprint]
    support = [here / n for n in ['BoundaryDoubles.swift', 'Cases.swift', 'test_contract.py', 'generate_fixture.py']]
    text = runner.read_text()
    helper = text.split('// V3_HOST_REFRESH_BUNDLE_PREPARATION_BEGIN\n', 1)[1].split('// V3_HOST_REFRESH_BUNDLE_PREPARATION_END', 1)[0]
    start = text.index('        var preparedHostRefreshBundle:')
    end = text.index('        context.beginInstallationHandler', start)
    integration = text[start:end]
    # The selector, real helper invocation, catches and ownership defer are
    # extracted verbatim. Only the surrounding iOS runner/pipeline is doubled.
    integration = 'func runIntegration(operation: AppOperation, context: FixtureContext, body: (FixtureContext) throws -> Void) throws {\n' + integration + '\n    try body(context)\n}\n'
    cases = (here / 'Cases.swift').read_text()
    names = []
    for name in re.findall(r'\brecord\("([^"\n]+)"', cases):
        if r'\(checkpointToCancel)' in name:
            names.extend(name.replace(r'\(checkpointToCancel)', str(i)) for i in range(1, 6))
        else:
            names.append(name)
    assert len(names) == len(set(names)), 'Duplicate fixture names'
    source = '\n'.join([(here / 'BoundaryDoubles.swift').read_text(), fingerprint.read_text(), helper, integration, cases])
    out.mkdir(parents=True, exist_ok=True)
    generated = out / 'host-refresh-bundle.swift'
    generated.write_text(source)
    def entry(p):
        try: name = str(p.relative_to(root))
        except ValueError: name = str(p)
        return {'path': name, 'sha256': sha(p)}
    receipt = {'schema': 'v3-host-refresh-bundle-source-v1', 'pass': True,
        'inputs': [entry(p) for p in inputs], 'support': [entry(p) for p in support],
        'generated_source': {'path': generated.name, 'sha256': sha(generated)},
        'source_assertion_count': assertions, 'expected_case_names': names, 'expected_case_count': len(names),
        'swift_executed': False, 'network_executed': False, 'provider_executed': False, 'device_executed': False}
    (out / 'sources.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
