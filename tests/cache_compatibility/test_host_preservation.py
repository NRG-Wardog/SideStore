import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile
import json

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('cache_generator_review', HERE / 'generate_fixture.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class HostPreservationTests(unittest.TestCase):
    def setUp(self):
        self.host = (HERE.parents[1] / generator.PRODUCTION['host']).read_text()

    def test_current_exact_guard_and_original_host_are_distinguished(self):
        proof = generator.verify_host_preservation(self.host)
        self.assertIs(proof['host_pipeline_byte_identical'], False)
        self.assertIs(proof['host_pipeline_except_reviewed_refresh_truth_cold_vpn_and_reuse_main_byte_identical'], True)
        self.assertNotIn('host_pipeline_except_reviewed_cold_vpn_and_reuse_main_byte_identical', proof)
        prior, applied = generator.project_reviewed_cold_vpn(generator.project_reviewed_refresh_truth(self.host)[0])
        self.assertIs(applied, True)
        self.assertTrue(generator.verify_host_preservation(prior)['host_pipeline_except_reviewed_reuse_main_byte_identical'])
        original = prior.replace(generator.REVIEWED_REUSE_MAIN_INSERTION, '', 1)
        self.assertEqual(generator.verify_host_preservation(original), {'host_pipeline_byte_identical': True})

    def test_reviewed_delta_is_pinned_and_reconstructs_exact_source(self):
        raw = (HERE / 'reviewed-cold-vpn-host-delta.json').read_bytes()
        receipt = json.loads(raw)
        projected, applied = generator.project_reviewed_refresh_truth(self.host)
        self.assertTrue(applied)
        self.assertEqual(generator.digest(projected.encode()), receipt['after_sha256'])
        prior, _ = generator.project_reviewed_cold_vpn(generator.project_reviewed_refresh_truth(self.host)[0])
        self.assertEqual(generator.digest(prior.encode()), receipt['before_sha256'])
        rebuilt = prior
        for hunk in receipt['hunks']:
            self.assertEqual(rebuilt.count(hunk['before']), 1)
            rebuilt = rebuilt.replace(hunk['before'], hunk['after'], 1)
        self.assertEqual(rebuilt, projected)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            (root / 'reviewed-cold-vpn-host-delta.json').write_bytes(raw + b' ')
            (root / 'reviewed-refresh-truth-host-delta.json').write_bytes((HERE / 'reviewed-refresh-truth-host-delta.json').read_bytes())
            with patch.object(generator, 'HERE', root):
                with self.assertRaisesRegex(AssertionError, 'Reviewed cold-VPN delta changed'):
                    generator.verify_host_preservation(self.host)

    def test_truth_projection_exact_and_tamper_rejection(self):
        raw = (HERE / 'reviewed-refresh-truth-host-delta.json').read_bytes()
        receipt = json.loads(raw)
        previous, applied = generator.project_reviewed_refresh_truth(self.host)
        self.assertTrue(applied)
        self.assertEqual(generator.digest(previous.encode()), receipt['before_sha256'])
        rebuilt = previous
        for hunk in receipt['hunks']:
            self.assertEqual(rebuilt.count(hunk['before']), 1)
            rebuilt = rebuilt.replace(hunk['before'], hunk['after'], 1)
        self.assertEqual(rebuilt, self.host)
        for changed in [self.host.replace('context.recordRefreshVerification =', 'context.recordRefreshVerification /* changed */ =', 1),
                        self.host.replace('readProfiles: readProfiles', 'readProfiles: nil', 1),
                        self.host + '\n// unrelated change\n', self.host + receipt['hunks'][0]['after']]:
            self.assertNotEqual(changed, self.host)
            with self.assertRaises(AssertionError): generator.verify_host_preservation(changed)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / 'reviewed-refresh-truth-host-delta.json').write_bytes(raw + b' ')
            with patch.object(generator, 'HERE', root):
                with self.assertRaisesRegex(AssertionError, 'Reviewed refresh-truth delta changed'):
                    generator.verify_host_preservation(self.host)

    def test_changed_partial_duplicate_cold_vpn_and_missing_admission_reject(self):
        for text in (
            self.host.replace('static let maximumProbes = 12', 'static let maximumProbes = 120'),
            self.host.replace('try readinessLifetime.check()', '// lifetime bypassed', 1),
            self.host.replace('refreshAdmission: checkReadinessOwnership', 'refreshAdmission: nil', 1),
            self.host.replace('ownedNetworkReadinessProbe', 'ownedReadinessProbe', 1),
            self.host.replace('// V3_OWNED_REFRESH_READINESS_WAIT_V1:', '// hidden marker:', 1),
            self.host + self.host.split('// V3_OWNED_REFRESH_READINESS_WAIT_V1:', 1)[1].split('// V3_OWNED_REFRESH_READINESS_WAIT_END', 1)[0],
        ):
            with self.subTest(text=text[-70:]):
                with self.assertRaises(AssertionError):
                    generator.verify_host_preservation(text)

    def test_changed_guard_duplicate_guard_and_unrelated_change_reject(self):
        for text in (self.host.replace('context.validatedReuseMain = app.useMainProfile', 'context.validatedReuseMain = true'),
                     self.host + generator.REVIEWED_REUSE_MAIN_INSERTION,
                     self.host + '\n// unrelated host change\n',
                     self.host.replace('AppBundleFingerprint.compute(for:', 'AppBundleFingerprint.computeOriginalCacheKey(for:', 1)):
            with self.subTest(text=text[-70:]):
                with self.assertRaises(AssertionError):
                    generator.verify_host_preservation(text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
