import importlib.util
from pathlib import Path
import unittest

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
        self.assertIs(proof['host_pipeline_except_reviewed_reuse_main_byte_identical'], True)
        original = self.host.replace(generator.REVIEWED_REUSE_MAIN_INSERTION, '', 1)
        self.assertEqual(generator.verify_host_preservation(original), {'host_pipeline_byte_identical': True})

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
