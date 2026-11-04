"""Portable runner-contract tests. These are NOT native recovery qualification."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('recovery_runner', HERE / 'run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class RunnerContract(unittest.TestCase):
    def project(self, version='5.0'):
        return {'objects': {
            'target': {'isa': 'PBXNativeTarget', 'name': 'SideStore', 'buildConfigurationList': 'list'},
            'other': {'isa': 'PBXNativeTarget', 'name': 'SideBackup', 'buildConfigurationList': 'other-list'},
            'list': {'isa': 'XCConfigurationList', 'buildConfigurations': ['release']},
            'other-list': {'isa': 'XCConfigurationList', 'buildConfigurations': ['other-release']},
            'release': {'isa': 'XCBuildConfiguration', 'name': 'Release', 'buildSettings': {'SWIFT_VERSION': version}},
            'other-release': {'isa': 'XCBuildConfiguration', 'name': 'Release', 'buildSettings': {'SWIFT_VERSION': '6.0'}},
        }}

    def test_language_mode_comes_from_sidestore_not_other_target(self):
        from target_settings import settings_from_objects
        result = settings_from_objects(self.project())
        self.assertEqual(result, {'target': 'SideStore', 'configuration': 'Release',
                                 'declared': '5.0', 'swiftc_argument': '5'})
        self.assertEqual(settings_from_objects(self.project('6.0'))['swiftc_argument'], '6')

    def test_unknown_or_inherited_language_mode_is_not_silently_downgraded(self):
        from target_settings import settings_from_objects
        for version in (None, '7.0', '$(inherited)', '5'):
            with self.assertRaises(ValueError):
                settings_from_objects(self.project(version))

    def test_canonical_fixture_root_keeps_nofollow_negative(self):
        source = (HERE/'run.py').read_text()
        self.assertIn('pathlib.Path(temporary).resolve(strict=True)', source)
        native = (HERE/'main.swift').read_text()
        self.assertIn('run("source-ancestor-symlink")', native)
        self.assertIn('NOFOLLOW accepted a linked ancestor', native)
        self.assertIn('FAILED_CASE', native)
        self.assertIn('PATH_PROBE foundation_matches_posix=', native)
        self.assertIn('PATH_PROBE posix_source_lease=pass', native)
        self.assertIn('CASE_PHASE wal-relocation-and-resume initial-resolve', native)

    def test_final_success_is_written_only_after_source_immutability_check(self):
        source = (HERE/'run.py').read_text()
        self.assertLess(source.index("raise RuntimeError('Production inputs changed"),
                        source.index("(output / 'report.json').write_text"))
        self.assertIn('Fresh output is required', source)

    def test_silent_command_has_nonempty_bounded_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = pathlib.Path(temporary)/'compile.log'
            runner.run([sys.executable, '-c', 'pass'], log)
            self.assertIn('"return_code": 0', log.read_text())
            self.assertIn('"stage": "compile.log"', log.read_text())
            with self.assertRaises(subprocess.CalledProcessError):
                runner.run([sys.executable, '-c', 'raise SystemExit(3)'], log)
            self.assertIn('"return_code": 3', log.read_text())

    def test_exact_production_inputs(self):
        paths = runner.source_paths()
        self.assertEqual(paths[0], runner.ROOT / 'SideStore/DatabaseRecovery.swift')
        self.assertEqual(paths[1], runner.ROOT / 'SideStore/DatabaseRecoverySQLite.c')
        self.assertTrue(all(path.is_file() for path in paths))

    def test_unsupported_host_is_failure(self):
        with patch.object(runner.platform, 'system', return_value='Linux'):
            with self.assertRaisesRegex(RuntimeError, 'NOT RUN'):
                runner.require_native()

    def test_report_requires_every_case(self):
        report = {'status': 'PASS_NATIVE_EXACT_ENGINE_SYNTHETIC_SQLITE',
                  'cases': sorted(runner.EXPECTED_CASES), 'production_coredata_validation': False}
        runner.verify_report(report)
        report['cases'].pop()
        with self.assertRaises(RuntimeError):
            runner.verify_report(report)

    def test_source_declares_all_cases(self):
        source = (HERE / 'main.swift').read_text()
        for case in runner.EXPECTED_CASES:
            self.assertIn(f'run("{case}")', source)
        self.assertIn('_exit(0)', source)
        self.assertIn('writer-blocked', source)
        self.assertIn('child("exit-before-publication", fixture.root)', source)
        self.assertEqual(source.count('child("exit-after-publication", fixture.root)'), 2)
        self.assertIn('Post-death legacy commit missing', source)
        self.assertIn('Retry deleted another invocation', source)

if __name__ == '__main__':
    unittest.main()
