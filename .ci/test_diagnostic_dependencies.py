"""Offline adversarial fixtures; synthetic resolver receipts are not native evidence."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('diagnostic_dependencies', ROOT / '.ci/production-dependencies.py')
PROOF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROOF)


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name).resolve()
        self.root = self.folder / 'repo'
        subprocess.run(['git', 'clone', '--quiet', '--no-hardlinks', str(ROOT), str(self.root)], check=True)
        self.raw_git('checkout', '--quiet', '--detach', PROOF.DIAGNOSTIC_SOURCE_CHECKPOINT['commit'])
        for path in PROOF.DIAGNOSTIC_METADATA:
            (self.root / path).write_bytes((ROOT / path).read_bytes())
        self.raw_git('update-index', '--cacheinfo', '160000,' + '1' * 40 + ',' + PROOF.DIAGNOSTIC_CHILD)
        self.commit()
        self.basis_path = self.folder / 'basis.json'
        self.receipt_path = None
        self.receipt_sha256 = None
        self.refresh_basis()

    def raw_git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), '-c', 'user.name=Proof Test',
            '-c', 'user.email=proof@example.invalid', *args], stderr=subprocess.PIPE)

    def commit(self):
        self.raw_git('add', '-f', '-A')
        self.raw_git('commit', '--quiet', '-m', 'isolated diagnostic mutation fixture')

    def save_basis(self):
        self.basis_path.write_text(json.dumps(self.basis, sort_keys=True, indent=2) + '\n')
        self.basis_sha256 = PROOF.sha(self.basis_path.read_bytes())

    def refresh_basis(self):
        before = PROOF.inventory(self.root, PROOF.DIAGNOSTIC_SOURCE_CHECKPOINT['commit'])
        after = PROOF.inventory(self.root, 'HEAD')
        data = PROOF.blobs(self.root, {e[2] for e in list(before.values()) + list(after.values()) if e[1] == 'blob'})
        changes = {p: {'before': PROOF.diagnostic_row(before.get(p), data),
                       'after': PROOF.diagnostic_row(after.get(p), data)}
                   for p in set(before) | set(after) if before.get(p) != after.get(p)}
        self.basis = {'schema_version': 1, 'owner': 'SideStore',
            'purpose': 'diagnostic_dependency_source_transition',
            'source_registry_sha256': PROOF.DIAGNOSTIC_REGISTRY_SHA256,
            'source_delta_sha256': PROOF.DIAGNOSTIC_DELTA_SHA256,
            'source_checkpoint': dict(PROOF.DIAGNOSTIC_SOURCE_CHECKPOINT),
            'accepted': dict(PROOF.DIAGNOSTIC_ACCEPTED),
            'candidate': {'commit': self.raw_git('rev-parse', 'HEAD').decode().strip(),
                          'tree': self.raw_git('rev-parse', 'HEAD^{tree}').decode().strip()},
            'anisette': {'repository': PROOF.ANISETTE_URL, 'accepted_commit': PROOF.DIAGNOSTIC_ACCEPTED_ANISETTE,
                         'diagnostic_commit': PROOF.DIAGNOSTIC_ANISETTE},
            'sidesign': {'repository': 'https://github.com/NRG-Wardog/SideSign.git',
                         'commit': '1' * 40, 'tree': '2' * 40, 'basis_sha256': '3' * 64},
            'changes': changes}
        self.save_basis()

    def prove(self, root=None):
        return PROOF.verify_diagnostic(root or self.root, basis_path=self.basis_path,
            basis_sha256=self.basis_sha256, resolver_receipt_path=self.receipt_path,
            resolver_receipt_sha256=self.receipt_sha256)

    def mutate(self, path, suffix=b'\n// unexpected mutation\n'):
        target = self.root / path
        target.write_bytes(target.read_bytes() + suffix)
        self.commit()
        self.refresh_basis()

    def resolver_fixture(self, *, origin_hash=None):
        # This constructs unit-test input only, never an actual native receipt.
        tested = copy.deepcopy(self.basis['candidate'])
        lock = json.loads((self.root / PROOF.DIAGNOSTIC_LOCK).read_bytes())
        PROOF.pin_map(lock)['anisettekit']['state']['revision'] = PROOF.DIAGNOSTIC_ANISETTE
        lock.pop('originHash', None)  # Synthetic fixtures exercise both observed states.
        if origin_hash is not None:
            lock['originHash'] = origin_hash
        (self.root / PROOF.DIAGNOSTIC_LOCK).write_text(json.dumps(lock, indent=2) + '\n')
        self.commit()
        self.refresh_basis()
        self.receipt = {'schema_version': 1, 'owner': 'SideStore', 'purpose': 'diagnostic_xcode_resolution',
            'run_url': 'https://github.com/NRG-Wardog/LiveContainer/actions/runs/1', 'run_attempt': 1,
            'resolver_tested_commit': tested['commit'], 'resolver_tested_tree': tested['tree'],
            'lock_sha256': PROOF.sha((self.root / PROOF.DIAGNOSTIC_LOCK).read_bytes()),
            'origin_hash': PROOF.observed_origin_hash(lock),
            'toolchain': {'xcode': 'SYNTHETIC TEST FIXTURE', 'swift': 'SYNTHETIC TEST FIXTURE'},
            'command': ['xcodebuild', '-resolvePackageDependencies', '-project', 'AltStore.xcodeproj'],
            'evidence_sha256': {name: '1' * 64 for name in
                ('resolver_log', 'resolution_before', 'resolution_after')}}
        self.save_receipt()

    def save_receipt(self):
        self.receipt_path = self.folder / 'synthetic-resolver-fixture.json'
        self.receipt_path.write_text(json.dumps(self.receipt, sort_keys=True, indent=2) + '\n')
        self.receipt_sha256 = PROOF.sha(self.receipt_path.read_bytes())

    def test_pending_source_proof_is_repeatable_and_never_ready(self):
        proof = self.prove()
        self.assertEqual(proof, self.prove())
        self.assertEqual(proof['status'], 'diagnostic_dependency_transition_pass')
        self.assertEqual(proof['lock_status'], 'accepted_lock_retained_pending_resolution')
        self.assertEqual(proof['unrelated_swiftpm_pins_preserved'], 9)
        self.assertFalse(proof['production_ready'])
        self.assertEqual(proof['native_validation_status'], 'not_established_for_candidate')
        self.assertTrue(proof['historical_receipts_only'])
        self.assertEqual(proof['origin_hash'], {'present': True, 'value': 'c9e3c6042136849ac21835264cf5aece849ed3e487b36b9242a3ab0b5fcf6d17'})
        self.assertEqual(proof['runtime_source_changes'], [])

    def test_default_gate_rejects_diagnostic_candidate(self):
        with self.assertRaisesRegex(PROOF.ProofError, 'Committed inventory drift'):
            PROOF.verify(self.root)

    def test_cli_requires_explicit_complete_diagnostic_mode(self):
        command = [sys.executable, '-B', str(self.root / '.ci/production-dependencies.py'),
                   '--root', str(self.root)]
        flags = ['--diagnostic-basis', str(self.basis_path),
                 '--diagnostic-basis-sha256', self.basis_sha256]
        result = subprocess.run(command + flags, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['production_ready'])
        for options in ([], flags[:2], flags + ['--allow-pending-child-pins']):
            with self.subTest(options=options):
                result = subprocess.run(command + options, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)

    def test_default_gate_still_accepts_legacy_graph(self):
        self.raw_git('checkout', '--quiet', '--detach', 'dd4f0ca36e8ef1d858548f583c65842a8fc0ced3')
        proof = PROOF.verify(self.root)
        self.assertEqual(proof['status'], 'exact_dependency_transition_pass')
        self.assertTrue(proof['production_ready'])

    def test_missing_and_wrong_basis_hash_rejected(self):
        for digest in (None, '0' * 64):
            with self.subTest(digest=digest), self.assertRaisesRegex(PROOF.ProofError, 'SHA256'):
                PROOF.verify_diagnostic(self.root, basis_path=self.basis_path, basis_sha256=digest)

    def test_readiness_and_receipt_fields_cannot_enter_source_basis(self):
        for key, value in [('production_ready', True), ('native_receipt', {}), ('status', 'PASS')]:
            with self.subTest(key=key):
                self.basis[key] = value
                self.save_basis()
                with self.assertRaisesRegex(PROOF.ProofError, 'outcomes belong in separate receipts'):
                    self.prove()
                del self.basis[key]

    def test_duplicate_json_key_rejected_even_with_approved_hash(self):
        encoded = self.basis_path.read_text().replace('"owner": "SideStore",', '"owner": "SideStore", "owner": "SideStore",')
        self.basis_path.write_text(encoded)
        self.basis_sha256 = PROOF.sha(self.basis_path.read_bytes())
        with self.assertRaisesRegex(PROOF.ProofError, 'Duplicate JSON key'):
            self.prove()

    def test_wrong_base_commit_and_tree_rejected(self):
        for key in ('commit', 'tree'):
            with self.subTest(key=key):
                self.basis['accepted'] = dict(PROOF.DIAGNOSTIC_ACCEPTED)
                self.basis['accepted'][key] = '0' * 40
                self.save_basis()
                with self.assertRaisesRegex(PROOF.ProofError, 'accepted production base'):
                    self.prove()

    def test_wrong_registry_and_anisette_pin_rejected(self):
        self.basis['source_registry_sha256'] = '0' * 64
        self.save_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'source registry'):
            self.prove()
        self.basis['source_registry_sha256'] = PROOF.DIAGNOSTIC_REGISTRY_SHA256
        self.basis['anisette']['diagnostic_commit'] = PROOF.ANISETTE
        self.save_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'AnisetteKit pin'):
            self.prove()

    def test_unreviewed_registry_placeholder_is_rejected(self):
        with patch.object(PROOF, 'DIAGNOSTIC_REGISTRY_SHA256', None):
            with self.assertRaisesRegex(PROOF.ProofError, 'registry awaiting reviewed hash'):
                self.prove()

    def test_diagnostic_accepted_pin_cannot_reuse_legacy_default_pin(self):
        self.assertNotEqual(PROOF.DIAGNOSTIC_ACCEPTED_ANISETTE, PROOF.ANISETTE)
        self.basis['anisette']['accepted_commit'] = PROOF.ANISETTE
        self.save_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'diagnostic AnisetteKit pin'):
            self.prove()

    def test_unreviewed_source_delta_placeholder_is_rejected(self):
        with patch.object(PROOF, 'DIAGNOSTIC_DELTA_SHA256', None):
            with self.assertRaisesRegex(PROOF.ProofError, 'delta awaiting reviewed hash'):
                self.prove()

    def test_wrong_candidate_commit_and_tree_rejected(self):
        for key in ('commit', 'tree'):
            with self.subTest(key=key):
                self.refresh_basis()
                self.basis['candidate'][key] = '0' * 40
                self.save_basis()
                with self.assertRaisesRegex(PROOF.ProofError, 'candidate commit/tree'):
                    self.prove()

    def test_runtime_drift_cannot_be_approved_in_basis(self):
        self.mutate('AltStore/AppDelegate.swift')
        with self.assertRaisesRegex(PROOF.ProofError, 'outside exact dependency/verifier metadata scope'):
            self.prove()

    def test_frozen_receipts_cannot_be_changed(self):
        self.mutate('.ci/production-dependencies.json', b'\n')
        with self.assertRaisesRegex(PROOF.ProofError, 'outside exact dependency/verifier metadata scope'):
            self.prove()

    def test_changed_basis_metadata_hash_rejected(self):
        self.basis['changes']['.ci/production-dependencies.py']['after']['sha256'] = '0' * 64
        self.save_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'blob/mode/hash mismatch'):
            self.prove()

    def test_committed_metadata_mode_drift_rejected(self):
        (self.root / '.ci/production-dependencies.py').chmod(0o755)
        self.commit()
        self.refresh_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'transition file type/mode drift'):
            self.prove()

    def test_extra_committed_file_rejected(self):
        (self.root / 'Unexpected.swift').write_text('let unexpected = true\n')
        self.commit()
        self.refresh_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'committed inventory drift'):
            self.prove()

    def test_wrong_child_pin_rejected_even_if_row_hash_approved(self):
        self.raw_git('update-index', '--cacheinfo', '160000,' + '4' * 40 + ',' + PROOF.DIAGNOSTIC_CHILD)
        self.commit()
        self.refresh_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'gitlink differs from approved dependency identity'):
            self.prove()

    def test_old_or_unresolved_child_identity_rejected(self):
        for identity in (None, PROOF.DIAGNOSTIC_ACCEPTED_SIDESIGN, '0' * 40):
            with self.subTest(identity=identity):
                self.basis['sidesign']['commit'] = identity
                self.save_basis()
                with self.assertRaisesRegex(PROOF.ProofError, 'Unresolved or invalid'):
                    self.prove()

    def test_child_gitlink_cannot_remain_on_accepted_graph(self):
        self.raw_git('update-index', '--cacheinfo', '160000,' + PROOF.DIAGNOSTIC_ACCEPTED_SIDESIGN + ',' + PROOF.DIAGNOSTIC_CHILD)
        self.commit()
        self.refresh_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'Missing reviewed diagnostic metadata or SideSign'):
            self.prove()

    def test_minimuxer_gitlink_drift_rejected(self):
        self.raw_git('update-index', '--cacheinfo', '160000,' + '4' * 40 + ',Dependencies/minimuxer')
        self.commit()
        self.refresh_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'outside exact dependency/verifier metadata scope'):
            self.prove()

    def test_submodule_url_and_project_changes_rejected(self):
        for path in ('.gitmodules', 'AltStore.xcodeproj/project.pbxproj'):
            with self.subTest(path=path):
                self.mutate(path)
                with self.assertRaisesRegex(PROOF.ProofError, 'outside exact dependency/verifier metadata scope'):
                    self.prove()

    def test_wrong_source_checkpoint_and_delta_rejected(self):
        self.basis['source_checkpoint']['commit'] = PROOF.DIAGNOSTIC_ACCEPTED['commit']
        self.save_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'source checkpoint'):
            self.prove()
        self.basis['source_checkpoint'] = dict(PROOF.DIAGNOSTIC_SOURCE_CHECKPOINT)
        self.basis['source_delta_sha256'] = '0' * 64
        self.save_basis()
        with self.assertRaisesRegex(PROOF.ProofError, 'source delta'):
            self.prove()

    def test_changed_lock_without_receipt_rejected(self):
        self.resolver_fixture()
        self.receipt_path = None
        self.receipt_sha256 = None
        with self.assertRaisesRegex(PROOF.ProofError, 'resolver receipt requires'):
            self.prove()

    def test_pending_lock_cannot_claim_resolution(self):
        self.receipt_path = self.folder / 'unread-receipt.json'
        self.receipt_sha256 = '1' * 64
        with self.assertRaisesRegex(PROOF.ProofError, 'Pending unchanged lock cannot claim'):
            self.prove()

    def test_pending_lock_cannot_be_reformatted(self):
        self.mutate(PROOF.DIAGNOSTIC_LOCK, b'\n')
        with self.assertRaisesRegex(PROOF.ProofError, 'pin drift'):
            self.prove()

    def test_resolver_fixture_preserves_observed_origin_presence_and_absence(self):
        self.resolver_fixture()
        proof = self.prove()
        self.assertFalse(proof['production_ready'])
        self.assertEqual(proof['lock_status'], 'reviewed_resolver_observed_lock')
        self.assertEqual(proof['origin_hash'], {'present': False, 'value': None})
        self.raw_git('checkout', '--quiet', '--detach', self.receipt['resolver_tested_commit'])
        self.refresh_basis()
        self.resolver_fixture(origin_hash='2' * 64)
        proof = self.prove()
        self.assertEqual(proof['origin_hash'], {'present': True, 'value': '2' * 64})
        self.assertFalse(proof['production_ready'])

    def test_extra_resolver_pin_movement_rejected(self):
        self.resolver_fixture()
        lock = json.loads((self.root / PROOF.DIAGNOSTIC_LOCK).read_text())
        PROOF.pin_map(lock)['codesignkit']['state']['revision'] = '0' * 40
        (self.root / PROOF.DIAGNOSTIC_LOCK).write_text(json.dumps(lock))
        self.commit()
        self.refresh_basis()
        self.receipt['lock_sha256'] = PROOF.sha((self.root / PROOF.DIAGNOSTIC_LOCK).read_bytes())
        self.save_receipt()
        with self.assertRaisesRegex(PROOF.ProofError, 'pin drift'):
            self.prove()

    def test_floating_and_duplicate_resolver_pins_rejected(self):
        self.resolver_fixture()
        lock = json.loads((self.root / PROOF.DIAGNOSTIC_LOCK).read_text())
        baseline = PROOF.git(self.root, 'show', PROOF.DIAGNOSTIC_ACCEPTED['commit'] + ':' + PROOF.DIAGNOSTIC_LOCK)
        floating = copy.deepcopy(lock)
        PROOF.pin_map(floating)['anisettekit']['state']['branch'] = 'main'
        duplicate = copy.deepcopy(lock)
        duplicate['pins'].append(copy.deepcopy(duplicate['pins'][0]))
        for current in (floating, duplicate):
            with self.subTest(current=current), self.assertRaises(PROOF.ProofError):
                PROOF.verify_diagnostic_lock(json.dumps(current).encode(), baseline)

    def test_fabricated_observed_origin_hash_rejected(self):
        self.resolver_fixture()
        self.receipt['origin_hash'] = {'present': True, 'value': '2' * 64}
        self.save_receipt()
        with self.assertRaisesRegex(PROOF.ProofError, 'originHash mismatch'):
            self.prove()

    def test_fake_readiness_in_resolver_receipt_rejected(self):
        self.resolver_fixture()
        self.receipt['production_ready'] = True
        self.save_receipt()
        with self.assertRaisesRegex(PROOF.ProofError, 'resolver receipt schema'):
            self.prove()

    def test_unapproved_receipt_and_wrong_lock_hash_rejected(self):
        self.resolver_fixture()
        self.receipt_sha256 = '0' * 64
        with self.assertRaisesRegex(PROOF.ProofError, 'receipt SHA256 mismatch'):
            self.prove()
        self.receipt['lock_sha256'] = '0' * 64
        self.save_receipt()
        with self.assertRaisesRegex(PROOF.ProofError, 'lock SHA256 mismatch'):
            self.prove()

    def test_old_accepted_native_receipt_cannot_stand_in_for_new_resolution(self):
        self.resolver_fixture()
        self.receipt['resolver_tested_commit'] = PROOF.DIAGNOSTIC_ACCEPTED['commit']
        self.receipt['resolver_tested_tree'] = PROOF.DIAGNOSTIC_ACCEPTED['tree']
        self.save_receipt()
        with self.assertRaisesRegex(PROOF.ProofError, 'outside captured lock'):
            self.prove()

    def test_shallow_history_rejected(self):
        (self.root / '.git/shallow').write_bytes(self.raw_git('rev-parse', 'HEAD'))
        with self.assertRaisesRegex(PROOF.ProofError, 'Shallow history'):
            self.prove()

    def test_assume_unchanged_cannot_hide_runtime_bytes(self):
        self.raw_git('update-index', '--assume-unchanged', 'AltStore/AppDelegate.swift')
        path = self.root / 'AltStore/AppDelegate.swift'
        path.write_bytes(path.read_bytes() + b'\n// hidden\n')
        with self.assertRaisesRegex(PROOF.ProofError, 'Uncommitted bytes'):
            self.prove()

    def test_hidden_metadata_bytes_rejected(self):
        self.raw_git('update-index', '--assume-unchanged', '.ci/production-dependencies.py')
        path = self.root / '.ci/production-dependencies.py'
        path.write_bytes(path.read_bytes() + b'\n# hidden\n')
        with self.assertRaisesRegex(PROOF.ProofError, 'Uncommitted bytes'):
            self.prove()

    def test_working_symlink_and_mode_changes_rejected(self):
        path = self.root / 'AltStore/AppDelegate.swift'
        path.chmod(0o755)
        with self.assertRaisesRegex(PROOF.ProofError, 'Working mode drift'):
            self.prove()
        path.unlink()
        path.symlink_to('/nonexistent-diagnostic-target')
        with self.assertRaisesRegex(PROOF.ProofError, 'Nonregular working file'):
            self.prove()

    def test_unknown_working_file_rejected(self):
        (self.root / 'Unexpected.swift').write_text('let unexpected = true\n')
        with self.assertRaisesRegex(PROOF.ProofError, 'Working inventory drift'):
            self.prove()

    def test_index_override_cannot_hide_staged_change(self):
        path = self.root / 'AltStore/AppDelegate.swift'
        original = path.read_bytes()
        path.write_bytes(original + b'\n// staged\n')
        self.raw_git('add', 'AltStore/AppDelegate.swift')
        path.write_bytes(original)
        with patch.dict(os.environ, {'GIT_INDEX_FILE': str(ROOT / '.git/index')}):
            with self.assertRaisesRegex(PROOF.ProofError, 'Index differs from HEAD'):
                self.prove()

    def test_clean_linked_worktree_and_initialized_submodule(self):
        linked = self.folder / 'linked'
        self.raw_git('worktree', 'add', '--quiet', '--detach', str(linked), 'HEAD')
        self.assertEqual(self.prove(linked), self.prove())
        parent = self.folder / 'parent'
        subprocess.run(['git', 'init', '--quiet', str(parent)], check=True)
        subprocess.run(['git', '-C', str(parent), '-c', 'protocol.file.allow=always',
                        'submodule', 'add', '--quiet', str(self.root), 'child'], check=True)
        self.assertEqual(self.prove(parent / 'child'), self.prove())


if __name__ == '__main__':
    unittest.main(verbosity=2)
