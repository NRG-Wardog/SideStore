"""Mutation tests for exact production wiring; never contact the network."""
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
SPEC = importlib.util.spec_from_file_location('production_dependencies', ROOT / '.ci/production-dependencies.py')
PROOF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROOF)


class LockTests(unittest.TestCase):
    def setUp(self):
        owner = json.loads((ROOT/'.ci/production-dependencies.json').read_text())['owner']
        path = PROOF.LOCKS[owner]
        self.before = json.loads(PROOF.git(ROOT, 'show', PROOF.CHECKPOINTS[owner] + ':' + path))
        self.current = json.loads((ROOT/path).read_text())

    def test_only_anisette_changed(self):
        self.assertEqual(PROOF.verify_lock(self.current, self.before), len(self.before['pins'])-1)

    def test_unrelated_revision_drift_rejected(self):
        self.current['pins'][1]['state']['revision'] = '0'*40
        with self.assertRaisesRegex(PROOF.ProofError, 'pin drift'):
            PROOF.verify_lock(self.current, self.before)

    def test_duplicate_package_identity_rejected(self):
        self.current['pins'].append(copy.deepcopy(self.current['pins'][0]))
        with self.assertRaisesRegex(PROOF.ProofError, 'Duplicate package'):
            PROOF.verify_lock(self.current, self.before)

    def test_floating_anisette_branch_rejected(self):
        self.current['pins'][0]['state']['branch'] = 'main'
        with self.assertRaisesRegex(PROOF.ProofError, 'pin drift'):
            PROOF.verify_lock(self.current, self.before)

    def test_fabricated_origin_hash_rejected(self):
        self.current['originHash'] = '0'*64
        with self.assertRaisesRegex(PROOF.ProofError, 'originHash'):
            PROOF.verify_lock(self.current, self.before)


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()/'repo'
        subprocess.run(['git','clone','--quiet','--no-hardlinks',str(ROOT),str(self.root)], check=True)
        self.owner = json.loads((self.root/'.ci/production-dependencies.json').read_text())['owner']
        self.source = self.root/('Sources/Logging.swift' if self.owner=='SideSign' else 'AltStore/AppDelegate.swift')

    def raw_git(self, *args):
        return subprocess.check_output(['git','-C',str(self.root),'-c','user.name=Proof Test',
            '-c','user.email=proof@example.invalid',*args], stderr=subprocess.PIPE)

    def prove(self):
        return PROOF.verify(self.root, allow_pending_child_pins=True)

    def commit(self):
        self.raw_git('add','-A')
        self.raw_git('commit','--quiet','-m','mutation fixture')

    def test_exact_transition_and_repeatability(self):
        first = self.prove()
        self.assertEqual(first, self.prove())
        self.assertTrue(first['production_ready'])
        self.assertEqual(first['readiness_scope'], 'eligible_for_gated_full_build')
        self.assertEqual(first['native_tested_commit'], 'f6e9e0ed6c3f4d02e99a0dcff0660faa0e5372b8')
        self.assertNotEqual(first['commit'], first['native_tested_commit'])
        self.assertEqual(first['native_tested_children']['Dependencies/SideSign'], '5ce52d12f1846e1a08fad30ed27c4cbadd176529')
        self.assertTrue(first['final_exact_ref_ipa_build_required'])
        self.assertEqual(first['runtime_behavior_changes'], [])

    def test_missing_native_receipt_rejected(self):
        path = self.root/'.ci/production-dependencies.json'
        spec = json.loads(path.read_text())
        del spec['native_receipt']
        path.write_text(json.dumps(spec))
        self.commit()
        with self.assertRaisesRegex(PROOF.ProofError, 'Missing reviewed native receipt'):
            self.prove()

    def test_changed_native_receipt_rejected(self):
        path = self.root/'.ci/production-dependencies.json'
        spec = json.loads(path.read_text())
        spec['native_receipt']['native_tested_tree'] = '0'*40
        path.write_text(json.dumps(spec))
        self.commit()
        with self.assertRaisesRegex(PROOF.ProofError, 'Reviewed native receipt mismatch'):
            self.prove()

    def test_readiness_cannot_rebaseline_a_manifest_change(self):
        manifest = self.root/'.gitmodules'
        manifest.write_bytes(manifest.read_bytes()+b'\n# untested manifest change\n')
        path = self.root/'.ci/production-dependencies.json'
        spec = json.loads(path.read_text())
        spec['dependency_files']['.gitmodules']['production_sha256'] = PROOF.sha(manifest.read_bytes())
        path.write_text(json.dumps(spec))
        self.commit()
        with self.assertRaisesRegex(PROOF.ProofError, 'outside readiness metadata'):
            self.prove()

    def test_shallow_history_rejected(self):
        (self.root/'.git/shallow').write_bytes(self.raw_git('rev-parse','HEAD'))
        with self.assertRaisesRegex(PROOF.ProofError, 'Shallow history'):
            self.prove()

    def test_clean_linked_worktree_passes(self):
        linked = Path(self.temp.name).resolve()/'linked'
        self.raw_git('worktree','add','--quiet','--detach',str(linked),'HEAD')
        self.assertTrue((linked/'.git').is_file())
        self.assertEqual(PROOF.verify(linked, allow_pending_child_pins=True)['commit'], self.prove()['commit'])

    def test_clean_initialized_submodule_passes(self):
        parent = Path(self.temp.name).resolve()/'parent'
        subprocess.run(['git','init','--quiet',str(parent)],check=True)
        subprocess.run(['git','-C',str(parent),'-c','protocol.file.allow=always',
            'submodule','add','--quiet',str(self.root),'child'],check=True)
        child = parent/'child'
        self.assertTrue((child/'.git').is_file())
        self.assertEqual(PROOF.verify(child, allow_pending_child_pins=True)['commit'], self.prove()['commit'])

    def test_committed_runtime_drift_rejected(self):
        self.source.write_bytes(self.source.read_bytes()+b'\n// unexpected runtime edit\n')
        self.commit()
        with self.assertRaisesRegex(PROOF.ProofError, 'Frozen blob/mode changed'):
            self.prove()

    def test_assume_unchanged_cannot_hide_source_edit(self):
        self.raw_git('update-index','--assume-unchanged',str(self.source.relative_to(self.root)))
        self.source.write_bytes(self.source.read_bytes()+b'\n// hidden edit\n')
        with self.assertRaisesRegex(PROOF.ProofError, 'Uncommitted bytes'):
            self.prove()

    def test_hidden_proof_metadata_drift_rejected(self):
        path = self.root/'.ci/PRODUCTION_DEPENDENCIES.md'
        self.raw_git('update-index','--assume-unchanged',str(path.relative_to(self.root)))
        path.write_bytes(path.read_bytes()+b'\nmutation\n')
        with self.assertRaisesRegex(PROOF.ProofError, 'Uncommitted bytes'):
            self.prove()

    def test_runtime_symlink_substitution_rejected(self):
        self.source.unlink()
        self.source.symlink_to('/nonexistent-proof-target')
        with self.assertRaisesRegex(PROOF.ProofError, 'Nonregular working file'):
            self.prove()

    def test_unknown_untracked_file_rejected(self):
        (self.root/'Unexpected.swift').write_text('let unexpected = 1\n')
        with self.assertRaisesRegex(PROOF.ProofError, 'Working inventory drift'):
            self.prove()

    def test_commit_cannot_expand_dependency_allowlist(self):
        path = self.root/'.ci/production-dependencies.json'
        spec = json.loads(path.read_text())
        spec['dependency_files'][str(self.source.relative_to(self.root))] = {}
        path.write_text(json.dumps(spec))
        self.commit()
        with self.assertRaisesRegex(PROOF.ProofError, 'Dependency allowlist drift'):
            self.prove()

    def test_index_override_cannot_hide_staged_change(self):
        self.source.write_bytes(self.source.read_bytes()+b'\n// staged edit\n')
        self.raw_git('add',str(self.source.relative_to(self.root)))
        self.source.write_bytes(PROOF.git(ROOT,'show','HEAD:'+str(self.source.relative_to(self.root))))
        with patch.dict(os.environ, {'GIT_INDEX_FILE':str(ROOT/'.git/index')}):
            with self.assertRaisesRegex(PROOF.ProofError, 'Index differs'):
                self.prove()

    def test_pending_child_pin_fails_default(self):
        if self.owner != 'SideStore':
            self.assertEqual(PROOF.verify(self.root)['status'],'exact_dependency_transition_pass')
            return
        spec = json.loads((self.root/'.ci/production-dependencies.json').read_text())
        if spec['child_gitlinks']['Dependencies/SideSign'] is None:
            with self.assertRaisesRegex(PROOF.ProofError, 'Pending published SideSign'):
                PROOF.verify(self.root)
        else:
            self.assertEqual(PROOF.verify(self.root)['status'],'exact_dependency_transition_pass')


if __name__ == '__main__':
    unittest.main(verbosity=2)
