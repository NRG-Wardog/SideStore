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
        self.progress_owner = (HERE.parents[1] / generator.PRODUCTION['host']).read_text()
        self.production, applied = generator.project_reviewed_progress_owner(self.progress_owner)
        self.assertTrue(applied)
        self.preservation, applied = generator.project_reviewed_profile_transaction(self.production)
        self.assertTrue(applied)
        self.latest, applied = generator.project_reviewed_preservation_registry(self.preservation)
        self.assertTrue(applied)
        self.current, applied = generator.project_reviewed_legacy_replacement(self.latest)
        self.assertTrue(applied)
        self.host, applied = generator.project_reviewed_transport_observation(self.current)
        self.assertTrue(applied)

    def test_progress_owner_exact_reverse_retains_all_prior_proofs(self):
        receipt = json.loads((HERE / 'reviewed-progress-owner-host-delta.json').read_text())
        rebuilt = self.production
        for hunk in receipt['hunks']:
            self.assertEqual(rebuilt.count(hunk['before']), 1)
            rebuilt = rebuilt.replace(hunk['before'], hunk['after'], 1)
        self.assertEqual(rebuilt, self.progress_owner)
        proof = generator.verify_host_preservation(self.progress_owner)
        self.assertEqual(proof.pop('reviewed_progress_owner_delta_sha256'), generator.REVIEWED_PROGRESS_OWNER_DELTA_SHA256)
        self.assertEqual(proof, generator.verify_host_preservation(self.production))
        self.assertEqual(generator.project_reviewed_progress_owner(self.production), (self.production, False))

    def test_progress_owner_missing_duplicate_changed_or_unrelated_rejected(self):
        receipt = json.loads((HERE / 'reviewed-progress-owner-host-delta.json').read_text())
        changed_sources = [self.progress_owner + '// unrelated', self.progress_owner.replace('operationProgress: owned.progress', 'operationProgress: Progress()', 1)]
        for hunk in receipt['hunks']:
            changed_sources += [self.progress_owner.replace(hunk['after'], '', 1), self.progress_owner + hunk['after']]
        for changed in changed_sources:
            with self.assertRaises(AssertionError): generator.verify_host_preservation(changed)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(generator, 'HERE', root):
                with self.assertRaises(FileNotFoundError): generator.verify_host_preservation(self.progress_owner)
                (root / 'reviewed-progress-owner-host-delta.json').write_text('{}')
                with self.assertRaisesRegex(AssertionError, 'Progress owner receipt changed'): generator.verify_host_preservation(self.progress_owner)

    def test_profile_transaction_exact_reverse_retains_all_prior_proofs(self):
        receipt = json.loads((HERE / 'reviewed-profile-transaction-host-delta.json').read_text())
        rebuilt = self.preservation
        for hunk in receipt['hunks']:
            self.assertEqual(rebuilt.count(hunk['before']), 1)
            rebuilt = rebuilt.replace(hunk['before'], hunk['after'], 1)
        self.assertEqual(rebuilt, self.production)
        proof = generator.verify_host_preservation(self.production)
        self.assertEqual(proof.pop('reviewed_profile_transaction_delta_sha256'), generator.REVIEWED_PROFILE_TRANSACTION_DELTA_SHA256)
        self.assertEqual(proof, generator.verify_host_preservation(self.preservation))
        self.assertEqual(generator.project_reviewed_profile_transaction(self.preservation), (self.preservation, False))

    def test_profile_transaction_missing_duplicate_changed_or_unrelated_rejected(self):
        receipt = json.loads((HERE / 'reviewed-profile-transaction-host-delta.json').read_text())
        changed_sources = [self.production + '// unrelated', self.production.replace('try checkTransactionAdmission()', '// removed admission', 1)]
        for hunk in receipt['hunks']:
            changed_sources += [self.production.replace(hunk['after'], '', 1), self.production + hunk['after']]
        for changed in changed_sources:
            with self.assertRaises(AssertionError): generator.verify_host_preservation(changed)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(generator, 'HERE', root):
                with self.assertRaises(FileNotFoundError): generator.verify_host_preservation(self.production)
                (root / 'reviewed-profile-transaction-host-delta.json').write_text('{}')
                with self.assertRaisesRegex(AssertionError, 'Profile transaction receipt changed'): generator.verify_host_preservation(self.production)

    def test_preservation_exact_hunks_and_tamper_rejected(self):
        receipt = generator.preservation_receipt()
        rebuilt = self.latest
        for hunk in receipt['hunks']:
            self.assertEqual(rebuilt.count(hunk['before']), 1)
            rebuilt = rebuilt.replace(hunk['before'], hunk['after'], 1)
        self.assertEqual(rebuilt, self.preservation)
        proof = generator.verify_host_preservation(self.preservation)
        self.assertEqual(proof.pop('reviewed_preservation_registry_delta_sha256'), generator.REVIEWED_PRESERVATION_REGISTRY_DELTA_SHA256)
        self.assertEqual(proof, generator.verify_host_preservation(self.latest))
        for changed in [self.preservation + '\n// unrelated\n',
                        self.preservation.replace('context.validatedReuseMain = false', 'context.validatedReuseMain = true', 1),
                        self.preservation.replace(receipt['hunks'][0]['after'], '', 1),
                        self.preservation + receipt['hunks'][0]['after']]:
            with self.assertRaises(AssertionError): generator.verify_host_preservation(changed)

    def test_legacy_exact_delta_preserves_all_prior_layers(self):
        raw = (HERE / 'reviewed-legacy-replacement-host-delta.json').read_bytes()
        receipt = json.loads(raw)
        rebuilt = self.current
        for hunk in receipt['hunks']:
            self.assertEqual(rebuilt.count(hunk['before']), 1)
            rebuilt = rebuilt.replace(hunk['before'], hunk['after'], 1)
        self.assertEqual(rebuilt, self.latest)
        proof = generator.verify_host_preservation(self.latest)
        self.assertEqual(proof.pop('reviewed_legacy_replacement_delta_sha256'), generator.digest(raw))
        self.assertEqual(proof, generator.verify_host_preservation(self.current))

    def test_legacy_changed_missing_duplicate_or_unrelated_input_rejected(self):
        receipt = json.loads((HERE / 'reviewed-legacy-replacement-host-delta.json').read_bytes())
        for changed in (self.latest.replace('context.useMainProfile = false', 'context.useMainProfile = true'),
                        self.latest.replace('certificate.x509.data == binding.certificateDER', 'true'),
                        self.latest.replace('handler.legacyReplacementBinding', 'handler.unknownBinding'),
                        self.latest.replace(receipt['hunks'][0]['after'], '', 1),
                        self.latest + receipt['hunks'][0]['after'], self.latest + '\n// unrelated change\n'):
            with self.assertRaises(AssertionError): generator.verify_host_preservation(changed)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            raw = (HERE / 'reviewed-legacy-replacement-host-delta.json').read_bytes()
            (root / 'reviewed-legacy-replacement-host-delta.json').write_bytes(raw + b' ')
            with patch.object(generator, 'HERE', root):
                with self.assertRaisesRegex(AssertionError, 'Reviewed legacy-replacement delta changed'):
                    generator.verify_host_preservation(self.latest)

    def test_legacy_cache_key_caller_is_exact_and_never_standalone_identity_proof(self):
        receipt = json.loads((HERE / 'reviewed-legacy-replacement-host-delta.json').read_text())
        root = HERE.parents[1]
        caller = receipt['cache_key_caller']
        self.assertEqual(generator.verify_reviewed_cache_callers(root), {'SideStore/' + caller['path']: caller['sha256'], **{'SideStore/' + path: generator.digest((root / path).read_bytes()) for path in generator.preservation_receipt()['additional_cache_key_callers']}})
        with tempfile.TemporaryDirectory() as temporary:
            tmp = Path(temporary).resolve()
            for relative in (generator.PRODUCTION['cache'], caller['path']):
                destination = tmp / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((root / relative).read_bytes())
            self.assertTrue(generator.verify_reviewed_cache_callers(tmp))
            stage = tmp / caller['path']; original = stage.read_text()
            stage.write_text(original.replace('AppBundleFingerprint.compute(for: source.fileURL)', 'nil'))
            with self.assertRaises(AssertionError): generator.verify_reviewed_cache_callers(tmp)
            stage.write_text(original)
            (tmp / 'SideStore/Unreviewed.swift').write_text('AppBundleFingerprint.computeOriginalCacheKey(for: unknown)')
            with self.assertRaises(AssertionError): generator.verify_reviewed_cache_callers(tmp)

    def test_observation_projection_reconstructs_exact_frozen_truth_source(self):
        raw = (HERE / 'reviewed-transport-observation-host-delta.json').read_bytes()
        receipt = json.loads(raw)
        self.assertEqual(generator.digest(self.host.encode()), receipt['before_sha256'])
        rebuilt = self.host
        for hunk in receipt['hunks']:
            self.assertEqual(rebuilt.count(hunk['before']), 1)
            rebuilt = rebuilt.replace(hunk['before'], hunk['after'], 1)
        self.assertEqual(rebuilt, self.current)
        proof = generator.verify_host_preservation(self.current)
        self.assertEqual(proof['reviewed_transport_observation_delta_sha256'], generator.digest(raw))
        self.assertTrue(proof['host_pipeline_except_reviewed_refresh_truth_cold_vpn_and_reuse_main_byte_identical'])

    def test_observation_changed_missing_duplicate_and_unrelated_source_rejected(self):
        receipt = json.loads((HERE / 'reviewed-transport-observation-host-delta.json').read_bytes())
        for changed in (
            self.current.replace('nativeReady: true', 'nativeReady: false', 1),
            self.current.replace('configurationUnchanged: transportObservationConfiguration == .capture()', 'configurationUnchanged: true', 1),
            self.current.replace('V3TransportObservationConfiguration', 'OtherConfiguration'),
            self.current.replace(receipt['hunks'][0]['after'], '', 1),
            self.current + receipt['hunks'][0]['after'],
            self.current + '\n// unrelated change\n',
        ):
            with self.subTest(changed=changed[-40:]):
                with self.assertRaises(AssertionError): generator.verify_host_preservation(changed)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            raw = (HERE / 'reviewed-transport-observation-host-delta.json').read_bytes()
            (root / 'reviewed-transport-observation-host-delta.json').write_bytes(raw + b' ')
            (root / 'reviewed-legacy-replacement-host-delta.json').write_bytes((HERE / 'reviewed-legacy-replacement-host-delta.json').read_bytes())
            with patch.object(generator, 'HERE', root):
                with self.assertRaisesRegex(AssertionError, 'Reviewed transport-observation delta changed'):
                    generator.verify_host_preservation(self.current)

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
            (root / 'reviewed-transport-observation-host-delta.json').write_bytes((HERE / 'reviewed-transport-observation-host-delta.json').read_bytes())
            (root / 'reviewed-legacy-replacement-host-delta.json').write_bytes((HERE / 'reviewed-legacy-replacement-host-delta.json').read_bytes())
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
            (root / 'reviewed-transport-observation-host-delta.json').write_bytes((HERE / 'reviewed-transport-observation-host-delta.json').read_bytes())
            (root / 'reviewed-legacy-replacement-host-delta.json').write_bytes((HERE / 'reviewed-legacy-replacement-host-delta.json').read_bytes())
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



class RecoveryGetterBoundaryTests(unittest.TestCase):
    def test_installed_source_recovers_exact_frozen_baseline(self):
        source = (HERE.parents[1]/generator.PRODUCTION['installed']).read_text()
        original = generator.verify_installed_recovery_selection(source)
        self.assertEqual(generator.digest(original.encode()), generator.PINNED['installed'])
        self.assertEqual(source, original.replace('let appsDirectoryURL = baseDirectory.appendingPathComponent("Apps")',
            'let appsDirectoryURL = '+generator.RECOVERED_APPS_INSERTION+'baseDirectory.appendingPathComponent("Apps")', 1))
        for changed in (original,
                        source.replace('recoveredAppsDirectory ??', 'recoveredAppsDirectory!', 1),
                        source.replace('?? baseDirectory.appendingPathComponent("Apps")', '?? baseDirectory', 1),
                        source + generator.RECOVERED_APPS_INSERTION,
                        source + '\n// unrelated source change\n'):
            with self.assertRaises(AssertionError):
                generator.verify_installed_recovery_selection(changed)

    def test_exact_production_getter_is_retained_without_rewriting(self):
        source = (HERE.parents[1]/generator.PRODUCTION['installed']).read_text()
        getter = generator.verify_production_apps_getter(source)
        self.assertIn('MaintenanceManager.shared.recoveredAppsDirectory ?? baseDirectory.appendingPathComponent("Apps")', getter)
        self.assertIn('FileManager.default.createDirectory(at: appsDirectoryURL', getter)
        for changed in (source.replace('MaintenanceManager.shared.recoveredAppsDirectory ?? ', '', 1),
                        source.replace('withIntermediateDirectories: true, attributes: nil', 'withIntermediateDirectories: false, attributes: nil'),
                        source + getter):
            with self.assertRaises(AssertionError):
                generator.verify_production_apps_getter(changed)

    def test_boundary_only_supplies_optional_selection(self):
        boundary = generator.RECOVERY_SELECTION_BOUNDARY
        self.assertIn('var recoveredAppsDirectory: URL?', boundary)
        self.assertIn('AliasFixtureBoundary.recoveredAppsDirectory', boundary)
        for forbidden in ('func resolve', 'DatabaseRecovery', 'createDirectory', 'removeItem', 'FileManager', 'CoreData'):
            self.assertNotIn(forbidden, boundary)
        self.assertIn('production_root_getter = verify_production_apps_getter(source["installed"])', (HERE/'generate_fixture.py').read_text())

    def test_existing_alias_case_exercises_nil_and_selected_roots(self):
        import re
        source = (HERE/'Cases.swift').read_text()
        names = re.findall(r'^    \("([a-z0-9_]+)", \{', source, re.M)
        self.assertEqual(len(names), 26)
        self.assertEqual(len(set(names)), 26)
        case = source.split('("trusted_root_alias_before_fails_after_passes", { root in', 1)[1]
        self.assertIn('AliasFixtureBoundary.recoveredAppsDirectory = nil', case)
        self.assertIn('AliasFixtureBoundary.recoveredAppsDirectory = selectedApps', case)
        self.assertIn('InstalledApp.appsDirectoryURL == selectedApps', case)
        self.assertIn('Recovered getter/cache wrote fallback Apps', case)
        self.assertIn('try copied(source, recoveredCache.targetFileURL)', case)
        self.assertIn('Recovered cache changed source', case)


if __name__ == '__main__':
    unittest.main(verbosity=2)
