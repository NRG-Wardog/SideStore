"""Portable mutation guards for the owner CI source/lock boundary."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('maintained_dependencies', ROOT / 'scripts/ci/maintained_dependencies.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class DependencyInputTests(unittest.TestCase):
    def test_origin_metadata_does_not_change_pin_identity(self):
        before = {'version': 3, 'originHash': 'before', 'pins': [
            {'identity': 'a', 'location': 'https://example.invalid/a', 'state': {'revision': 'a' * 40}}]}
        after = copy.deepcopy(before)
        after['originHash'] = 'after'
        self.assertEqual(M.lock_identity(before), M.lock_identity(after))
        for mutation in ('location', 'state'):
            changed = copy.deepcopy(before)
            changed['pins'][0][mutation] = 'changed'
            self.assertNotEqual(M.lock_identity(before), M.lock_identity(changed))

    def test_duplicate_and_wrong_lock_schema_rejected(self):
        for lock in ({'version': 2, 'pins': []}, {'version': 3, 'pins': [{'identity': 'a'}, {'identity': 'a'}]}):
            with self.assertRaises(ValueError):
                M.lock_identity(lock)

    def test_acquisition_refuses_existing_directory_before_git_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'existing acquisition'):
                M.acquire(root, root)

    def test_gitlink_acquisition_rejects_existing_nonrepository_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'Dependencies/SideSign'
            target.mkdir(parents=True)
            (target / 'unrelated').write_text('preserve')
            with patch.object(M, 'git', return_value=M.GITLINKS['Dependencies/SideSign']):
                with self.assertRaisesRegex(ValueError, 'Nonempty uninitialized gitlink'):
                    M.acquire_gitlink(root, 'Dependencies/SideSign', M.GITLINKS['Dependencies/SideSign'])
            self.assertEqual((target / 'unrelated').read_text(), 'preserve')

    def test_workflow_uses_canonical_build_and_fail_closed_lock_gate(self):
        text = (ROOT / '.github/workflows/pr.yml').read_text()
        for required in ('cargo +1.98.1 build --locked', 'build_ios.py', 'embedded.py',
                         'verify_native_abi.py', 'maintained_dependencies.py verify-locks',
                         'xcodebuild -resolvePackageDependencies', 'if: always()'):
            self.assertIn(required, text)
        job_env = text.split('    env:', 1)[1].split('    steps:', 1)[0]
        self.assertNotIn('${{ runner.', job_env)
        self.assertIn('"$RUNNER_TEMP/sidestore-maintained-inputs" >> "$GITHUB_ENV"', text)
        self.assertNotIn('continue-on-error:', text)
        self.assertNotIn('actions/cache/restore', text)
        self.assertIn('submodules: false', text)
        self.assertNotIn('submodules: recursive', text)
        self.assertIn('GIT_CONFIG_GLOBAL: /dev/null', text)
        self.assertIn('retention-days: 14', text)
        self.assertIn('-onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution', text)
        makefile = (ROOT / 'Makefile').read_text()
        self.assertIn('XCODE_PACKAGE_FLAGS ?=', makefile)
        self.assertIn('$(COMMON_BUILD_SETTINGS) $(XCODE_PACKAGE_FLAGS)', makefile)


if __name__ == '__main__':
    unittest.main()
