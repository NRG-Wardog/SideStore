"""Offline source contract and override-selection model, not authentication."""
from pathlib import Path
import hashlib
import unittest
ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "SideStore/Core/Anisette/AnisetteConfigManager.swift").read_text()
MAC = "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

def model(user, file, on_device):
    resolved = user if user is not None and user != "" else file
    return MAC if resolved is None or resolved == "" else resolved

class DefaultClientInfoContract(unittest.TestCase):
    def test_both_modes_use_upstream_default(self):
        helper = SOURCE.split("public nonisolated static func defaultClientInfo",1)[1].split("public func loadConfig",1)[0]
        self.assertIn("AppConstants.Anisette.defaultClientInfo", helper)
        self.assertNotIn("?", helper)
        self.assertNotIn("Pixel 7", SOURCE)
        self.assertIn("forOnDeviceAndroid: Bool", helper)
        constants = (ROOT / "SideStore/AppConstants.swift").read_text()
        self.assertIn("defaultClientInfo           = Constants.Anisette.defaultClientInfo", constants)
    def test_explicit_overrides_are_not_changed(self):
        for mode in (False, True):
            for user, file, expected in [(None,None,MAC),("",None,MAC),(None,"",MAC),("","",MAC),
                    ("user",None,"user"),(None,"file","file"),("","file","file"),("user","file","user"),
                    ("user","","user"),(" ",None," "),("saved Android",None,"saved Android")]:
                with self.subTest(mode=mode,user=user,file=file): self.assertEqual(model(user,file,mode),expected)
        self.assertIn("(udClientInfo?.isEmpty == false ? udClientInfo : fileConfig?.clientInfo)", SOURCE)
        self.assertIn("config.clientInfo.isEmpty ? Self.defaultClientInfo(forOnDeviceAndroid: forOnDeviceAndroid) : config.clientInfo", SOURCE)
    def test_persistence_api_unchanged(self):
        value=SOURCE.split("    public func saveConfig(",1)[1].split("    public func importFromFile(",1)[0]
        value="    public func saveConfig("+value
        self.assertEqual(hashlib.sha256(value.encode()).hexdigest(), "cc1d0407bca759d1785f244413149a0c18b991da312502128f0a6f7d75802184")
    def test_verified_android_library_acquisition_unchanged(self):
        value=(ROOT / "SideStore/Core/Anisette/OnDeviceAnisetteManager.swift").read_bytes()
        self.assertEqual(hashlib.sha256(value).hexdigest(), "b318c722a1b44d44892237d34ee361d80a6df3f190db1fbd75f8e216cdbcfdf3")

if __name__ == "__main__": unittest.main(verbosity=2)
