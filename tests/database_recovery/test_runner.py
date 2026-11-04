"""Portable runner-contract tests. These are NOT native recovery qualification."""
import importlib.util
import pathlib
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('recovery_runner', HERE / 'run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class RunnerContract(unittest.TestCase):
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
