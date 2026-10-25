"""Execute the production row encoder with a synthetic portal model, no account data."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFT = shutil.which('swiftc')


def production_row():
    text = (ROOT / 'AltStore/AppDelegate.swift').read_text()
    start = text.index('    static func developerAppIDRow(')
    end = text.index('    static func developerAppIDs()', start)
    return text[start:end]


class AppIDExpiryBridgeTests(unittest.TestCase):
    def test_authoritative_date_source_and_account_scoped_route(self):
        source = (ROOT / 'AltStore/AppDelegate.swift').read_text()
        row = production_row()
        self.assertIn('appID.expirationDate', row)
        self.assertIn('row["expirationDate"] = expiration', row)
        self.assertNotIn('Date()', row)
        self.assertNotIn('expirationDate ??', row)
        self.assertIn('fetchAppIDs().map(developerAppIDRow)', source)
        self.assertIn('accountScopedRead("appIDs") { try await V3BackendCommands.developerAppIDs() }', source)

    @unittest.skipUnless(SWIFT, 'Swift compiler unavailable')
    def test_production_encoder_plist_round_trip(self):
        fixture = '''import Foundation
struct ALTAppID {
    let identifier: String
    let name: String
    let bundleIdentifier: String
    let expirationDate: Date?
}
enum Encoder {
__PRODUCTION__
}
let expiration = Date(timeIntervalSince1970: 1234567890)
for date in [expiration, nil, Date(timeIntervalSinceReferenceDate: .infinity)] as [Date?] {
    let app = ALTAppID(identifier: "synthetic", name: "Fixture", bundleIdentifier: "example.fixture", expirationDate: date)
    let row = Encoder.developerAppIDRow(app)
    let data = try PropertyListSerialization.data(fromPropertyList: row, format: .binary, options: 0)
    let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    precondition(decoded["identifier"] as? String == "synthetic")
    if date == expiration { precondition(decoded["expirationDate"] as? Date == expiration) }
    else { precondition(decoded["expirationDate"] == nil) }
}
print("APPID_EXPIRY_BRIDGE_PASS")
'''.replace('__PRODUCTION__', production_row())
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'main.swift'
            source.write_text(fixture)
            binary = Path(temp) / 'probe'
            build = subprocess.run([SWIFT, str(source), '-o', str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('APPID_EXPIRY_BRIDGE_PASS', run.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
