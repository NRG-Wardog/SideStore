"""Health wire presence is explicit, independent of account/team display names."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def health_source():
    source = (ROOT / 'AltStore/AppDelegate.swift').read_text()
    start = source.index('    static func health() async -> [String: Any] {')
    return source[start:source.index('\n    // Facts about the certificate', start)]


def assert_presence_contract(test, source):
    test.assertEqual(source.count('DatabaseManager.shared.activeAccount()'), 1)
    test.assertEqual(source.count('DatabaseManager.shared.activeTeam()'), 1)
    test.assertIn('let activeAccount = DatabaseManager.shared.activeAccount()', source)
    test.assertIn('let account = activeAccount?.appleID ?? "Not signed in"', source)
    test.assertIn('"activeAccountPresent": activeAccount != nil', source)
    test.assertIn('"activeTeamPresent": team != nil', source)


class HealthSnapshotContractTests(unittest.TestCase):
    def test_presence_uses_objects_from_same_observation_as_names(self):
        assert_presence_contract(self, health_source())

    def test_missing_or_name_inferred_flags_are_rejected(self):
        source = health_source()
        for original, replacement in (
            ('"activeAccountPresent": activeAccount != nil,', ''),
            ('"activeTeamPresent": team != nil,', ''),
            ('activeAccount != nil', 'account != "Not signed in"'),
            ('team != nil', 'team?.name != "No active team"'),
        ):
            with self.subTest(replacement=replacement):
                with self.assertRaises(AssertionError):
                    assert_presence_contract(self, source.replace(original, replacement))

    def test_real_health_function_encodes_boolean_presence_and_preserves_payload(self):
        swift = shutil.which('swiftc')
        if not swift:
            self.skipTest('Swift unavailable; native contract must run in macOS validation')
        fixture = (Path(__file__).with_name('health_snapshot_harness.swift')).read_text()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Health.swift'
            binary = Path(directory) / 'health'
            path.write_text(fixture.replace('__PRODUCTION_HEALTH__', health_source()))
            built = subprocess.run([swift, '-parse-as-library', str(path), '-o', str(binary)],
                                   capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('HEALTH_SNAPSHOT_CONTRACT_PASS', result.stdout)


if __name__ == '__main__':
    unittest.main()
