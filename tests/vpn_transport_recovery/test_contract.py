#!/usr/bin/env python3
"""Source-owned VPN policy/producer regression, with mandatory native CI mode."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import sys
sys.dont_write_bytecode = True
from generate_fixture import generate_source, declaration, producer_branch, transport_snapshot, wifi_readiness_branch, INPUTS, HERE

ROOT = Path(os.environ.get('VPN_TRANSPORT_SOURCE_ROOT', str(HERE.parents[2]))).resolve()

class VPNTransportContract(unittest.TestCase):
    def test_actual_source_extraction(self):
        text, paths = generate_source(ROOT)
        for key, anchor in [('scanner', 'internal enum NetworkIfaceScanner {'),
                            ('mapper', 'extension MinimuxerError {'),
                            ('classifier', 'func lcRefreshFailureFacts(')]:
            actual = declaration(paths[key].read_text(), anchor)
            self.assertIn(actual, text)
        producer = paths['producer'].read_text()
        self.assertIn(producer_branch(producer), text)
        self.assertIn(transport_snapshot(producer), text)
        self.assertIn(wifi_readiness_branch(producer), text)
        self.assertIn(declaration(paths['observer'].read_text(), '    struct Snapshot {'), text)
        self.assertIn('connectionMode == .localVPN ? localWiFi.satisfied : network.isWifiSatisfied', text)
        self.assertNotIn('import Darwin', text)
        self.assertNotIn('import DeviceGatewayAPI', text)
        self.assertNotIn('import MinimuxerCommon', text)
        self.assertIn('fixtureReadinessBeforeRepair', text)
        self.assertIn('fixtureReadinessResultBeforeRepair', text)
        self.assertIn('guard ifIndex != 0 else', text)
        self.assertIn('(!ifaceAddresses.v4.isEmpty || !ifaceAddresses.v6.isEmpty)', text)
        composed, _ = generate_source(ROOT, include_operation_classifier=False)
        self.assertNotIn('public enum OperationError:', composed)
        self.assertNotIn('func lcRefreshFailureFacts(', composed)

    def test_single_snapshot_and_family_confinement(self):
        producer = (ROOT / INPUTS['producer']).read_text()
        configure = declaration(producer, '    private func configureRefreshTransport()')
        self.assertEqual(configure.count('NetworkIfaceScanner.scan(quiet: true)'), 1)
        self.assertNotIn('network.isUTunAvailable', configure)
        self.assertNotIn('network.isIKEv2IPSecAvailable', configure)
        branch = producer_branch(producer)
        self.assertEqual(branch.count('.noVPN('), 1)
        self.assertIn('if decision.unavailableCause == .missingRequiredVPNInterface', branch)
        self.assertIn('.invalidVPN(decision.reason)', branch)
        for token in ['getConnectionMode', 'NetworkIfaceScanner', 'network.', 'localizedDescription']:
            self.assertNotIn(token, branch)
        policy = (ROOT / INPUTS['policy']).read_text()
        for cause in ['pairingUnavailable', 'connectionModeNotConfigured', 'missingRequiredVPNInterface', 'unsupportedBackend']:
            self.assertIn(cause, policy)
        self.assertLess(policy.index('if pairing == .unknown'), policy.index('guard utun else'))
        self.assertLess(policy.index('if mode == .remoteServer'), policy.index('guard utun else'))
        self.assertIn('modernOS && pairing == .lockdown && !coreDeviceSupported && !ipsec', policy)

    def test_frozen_exact_baseline(self):
        receipt = json.loads((HERE / 'baseline-receipt.json').read_text())
        self.assertEqual(receipt['minimuxer_commit'], '1d033920660c6f50b8f30c4c333f025867cd9e96')
        for name, spec in receipt['extracts'].items():
            data = (HERE / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), spec['sha256'])
            self.assertEqual(len(data), spec['bytes'])
        policy = (HERE / 'OriginalRefreshTransportPolicy.swift').read_bytes()
        self.assertEqual(hashlib.sha1(b'blob '+str(len(policy)).encode()+b'\0'+policy).hexdigest(), receipt['policy_git_blob'])
        self.assertIn('guard mode == .localVPN, utun else', policy.decode())
        self.assertNotIn('.noVPN(', (HERE / 'OriginalReadinessUnavailable.swift').read_text())

    def test_runtime_source_owned_swift(self):
        compiler = shutil.which('swiftc')
        if compiler is None:
            if os.environ.get('REQUIRE_SWIFT_VPN_TRANSPORT_TESTS') == '1':
                self.fail('Swift runtime tests are REQUIRED but compiler unavailable')
            self.skipTest('Swift compiler unavailable; generated-only, NOT a runtime pass')
        text, paths = generate_source(ROOT)
        text += (HERE / 'policy_cases.swift').read_text()
        evidence = os.environ.get('VPN_TRANSPORT_EVIDENCE_OUTPUT')
        if evidence:
            evidence = Path(evidence)
            evidence.mkdir(parents=True, exist_ok=True)
            (evidence / 'fixture.swift').write_text(text)
            (evidence / 'inputs.json').write_text(json.dumps({name: {
                'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()
            } for name, path in paths.items()}, indent=2) + '\n')
        with tempfile.TemporaryDirectory(prefix='vpn-transport-source-') as tmp:
            source = Path(tmp) / 'fixture.swift'; source.write_text(text)
            binary = Path(tmp) / 'fixture'
            compiled = subprocess.run([compiler, '-parse-as-library', str(source), '-o', str(binary)],
                                      text=True, capture_output=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stdout+compiled.stderr)
            completed = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
            self.assertEqual(completed.returncode, 0, completed.stdout+completed.stderr)
            marker = 'VPN_TRANSPORT_RECOVERY_PASS transport_cases=144 actual_scanner=pass baseline_failure_reproduced=pass finite_exclusions=pass'
            self.assertEqual(completed.stdout.splitlines().count(marker), 1, completed.stdout)
            if evidence:
                (evidence / 'runtime.log').write_text(completed.stdout + completed.stderr)
                (evidence / 'compiler.log').write_text(compiled.stdout + compiled.stderr)
            print(completed.stdout, end='')

if __name__ == '__main__':
    unittest.main(verbosity=2)
