"""Retained strict-cache historical MODEL plus current Swift SOURCE invariants.

The historical publication model is not the experiment's cache behavior.
Actual compatibility behavior is compiled in tests/cache_compatibility.
Neither these Python models nor source assertions execute Swift.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import stat
import tempfile
import unittest
import uuid

# Default paths always address the repository's maintained Swift sources.
REPO_ROOT = Path(os.environ.get("PRESERVATION_REPO_ROOT", str(Path(__file__).resolve().parents[2])))
SOURCE_FILES = {
    "AppBundleFingerprint.swift": REPO_ROOT / "SideStore/Utils/common/AppBundleFingerprint.swift",
    "CacheAppOperation.swift": REPO_ROOT / "SideStore/Core/Operations/PipelineOperations/CacheAppOperation.swift",
    "InstalledApp.swift": REPO_ROOT / "AltStore/Core/Model/InstalledApp.swift",
}
PREFIX = "content-v1-"


def node_digest(path):
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        raise ValueError("unsupported symlink")
    h = hashlib.sha256(f"SideStore-content-v1\nmode:{stat.S_IMODE(mode)}\n".encode())
    if path.is_dir():
        h.update(b"directory\n")
        for child in sorted(path.iterdir(), key=lambda p: p.name):
            name = child.name.encode()
            h.update(f"{len(name)}:".encode())
            h.update(name)
            h.update(node_digest(child))
    elif path.is_file():
        h.update(b"file\n")
        h.update(path.read_bytes())
    else:
        raise ValueError("unsupported entry")
    return h.digest()


def fingerprint(bundle):
    if not bundle.is_dir() or bundle.is_symlink():
        raise ValueError("not a regular bundle directory")
    return PREFIX + node_digest(bundle).hex()


def publish(bundle, cache, inject=None):
    signature = fingerprint(bundle)
    destination = cache / signature / "App.app"
    if destination.exists():
        if fingerprint(destination) != signature:
            raise ValueError("conflicting existing payload")
        return signature, destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = destination.parent / (".preservation-" + str(uuid.uuid4()))
    try:
        if inject == "copy_failure":
            stage.mkdir()
            (stage / "partial").write_bytes(b"owned incomplete fixture")
            raise OSError("injected copy failure")
        shutil.copytree(bundle, stage)
        if inject == "corrupt_stage":
            (stage / "binary").write_bytes(b"CORRUPT")
        if inject == "change_source":
            (bundle / "binary").write_bytes(b"CHANGED")
        if fingerprint(stage) != signature or fingerprint(bundle) != signature:
            raise ValueError("snapshot mismatch")
        if inject in ("race_same", "race_conflict"):
            shutil.copytree(bundle, destination)
            if inject == "race_conflict":
                (destination / "binary").write_bytes(b"OTHER")
        if destination.exists():
            if fingerprint(destination) != signature:
                raise ValueError("concurrent conflicting publication")
        else:
            # Single-writer directory model, not a test of Darwin/Foundation's
            # concurrent rename semantics. Race fixtures are injected above.
            stage.rename(destination)
        if fingerprint(destination) != signature:
            raise ValueError("published snapshot mismatch")
        return signature, destination
    finally:
        if stage.exists():
            shutil.rmtree(stage)


class RetainedStrictCacheModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="owned-cache-bundle-fixtures-")
        self.root = Path(self.temp.name)
        self.bundle = self.root / "source.app"
        self.bundle.mkdir()
        (self.bundle / "binary").write_bytes(b"AAAA")
        self.cache = self.root / "Payloads"
        self.cache.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def test_equal_length_binaries_have_distinct_keys(self):
        first = fingerprint(self.bundle)
        (self.bundle / "binary").write_bytes(b"BBBB")
        second = fingerprint(self.bundle)
        self.assertNotEqual(first, second)
        self.assertTrue(first.startswith(PREFIX))
        self.assertEqual(len(first), len(PREFIX) + 64)

    def test_hidden_files_and_signatures_and_profiles_affect_identity(self):
        for name in (".hidden", "_CodeSignature", "embedded.mobileprovision"):
            before = fingerprint(self.bundle)
            (self.bundle / name).write_bytes(b"FAKE only")
            self.assertNotEqual(before, fingerprint(self.bundle))

    def test_permission_change_changes_key(self):
        before = fingerprint(self.bundle)
        (self.bundle / "binary").chmod(0o700)
        self.assertNotEqual(before, fingerprint(self.bundle))

    def test_identical_existing_payload_reused_without_replacement(self):
        key, target = publish(self.bundle, self.cache)
        old = target.stat()
        self.assertEqual(publish(self.bundle, self.cache), (key, target))
        self.assertEqual(old, target.stat())
        self.assertEqual((self.bundle / "binary").read_bytes(), b"AAAA")

    def test_conflicting_existing_payload_fails_without_overwrite(self):
        key = fingerprint(self.bundle)
        target = self.cache / key / "App.app"
        target.parent.mkdir()
        shutil.copytree(self.bundle, target)
        (target / "binary").write_bytes(b"BBBB")
        with self.assertRaises(ValueError): publish(self.bundle, self.cache)
        self.assertEqual((target / "binary").read_bytes(), b"BBBB")
        self.assertEqual((self.bundle / "binary").read_bytes(), b"AAAA")

    def test_interrupted_copy_retains_source_and_is_retryable(self):
        key = fingerprint(self.bundle)
        with self.assertRaises(OSError): publish(self.bundle, self.cache, "copy_failure")
        self.assertFalse((self.cache / key / "App.app").exists())
        self.assertEqual(list(self.cache.glob("*/.preservation-*")), [])
        self.assertEqual((self.bundle / "binary").read_bytes(), b"AAAA")
        _, target = publish(self.bundle, self.cache)
        self.assertEqual((target / "binary").read_bytes(), b"AAAA")

    def test_corrupt_staging_is_not_published(self):
        key = fingerprint(self.bundle)
        with self.assertRaises(ValueError): publish(self.bundle, self.cache, "corrupt_stage")
        self.assertFalse((self.cache / key / "App.app").exists())
        self.assertEqual((self.bundle / "binary").read_bytes(), b"AAAA")

    def test_changed_source_is_not_published_under_old_key(self):
        key = fingerprint(self.bundle)
        with self.assertRaises(ValueError): publish(self.bundle, self.cache, "change_source")
        self.assertFalse((self.cache / key / "App.app").exists())
        self.assertEqual((self.bundle / "binary").read_bytes(), b"CHANGED")

    def test_concurrent_identical_publication_can_be_reused(self):
        key, target = publish(self.bundle, self.cache, "race_same")
        self.assertEqual(fingerprint(target), key)
        self.assertEqual((self.bundle / "binary").read_bytes(), b"AAAA")

    def test_concurrent_conflicting_publication_retained(self):
        key = fingerprint(self.bundle)
        with self.assertRaises(ValueError): publish(self.bundle, self.cache, "race_conflict")
        self.assertEqual((self.cache / key / "App.app" / "binary").read_bytes(), b"OTHER")
        self.assertEqual((self.bundle / "binary").read_bytes(), b"AAAA")

    def test_symlink_is_rejected_without_following_or_publishing(self):
        target = self.root / "other-owned-fixture"
        target.write_bytes(b"unchanged")
        (self.bundle / "link").symlink_to(target)
        with self.assertRaises(ValueError): publish(self.bundle, self.cache)
        self.assertEqual(list(self.cache.iterdir()), [])
        self.assertEqual(target.read_bytes(), b"unchanged")

    def test_same_structure_and_equal_size_bundles_publish_separately(self):
        key1, target1 = publish(self.bundle, self.cache)
        (self.bundle / "binary").write_bytes(b"BBBB")
        key2, target2 = publish(self.bundle, self.cache)
        self.assertNotEqual(key1, key2)
        self.assertEqual((target1 / "binary").read_bytes(), b"AAAA")
        self.assertEqual((target2 / "binary").read_bytes(), b"BBBB")


class SwiftSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.complete_fingerprint_source = SOURCE_FILES["AppBundleFingerprint.swift"].read_text()
        marker = "    // ORIGINAL_CACHE_COMPATIBILITY_BEGIN\n"
        cls.fingerprint_source = cls.complete_fingerprint_source.split(marker, 1)[0].rstrip() + "\n}\n"
        cls.cache_source = SOURCE_FILES["CacheAppOperation.swift"].read_text()
        cls.publication = cls.cache_source.split("static func cachePayload", 1)[1].split("static func pruneUnusedCaches", 1)[0]

    def test_versioned_key_and_real_bytes(self):
        # The complete delivered strict implementation, not merely tokens,
        # stays unchanged for host self-refresh and maintenance content proofs.
        self.assertEqual(hashlib.sha256(self.fingerprint_source.encode()).hexdigest(),
                         "c73ec2bfa43d56be919dac7fb824c0dc62a46f1830569d2b42697b52cd64ff67")
        self.assertIn('contentVersionPrefix = "content-v1-"', self.fingerprint_source)
        self.assertIn("FileHandle(forReadingFrom: url)", self.fingerprint_source)
        self.assertIn("hasher.update(data: chunk)", self.fingerprint_source)
        self.assertNotIn("fileSizeKey", self.fingerprint_source)
        self.assertNotIn(".skipsHiddenFiles", self.fingerprint_source)

    def test_symlinks_not_followed(self):
        self.assertIn("guard values.isSymbolicLink != true", self.fingerprint_source)
        self.assertIn("throw FingerprintError.unsupportedEntry", self.fingerprint_source)

    def test_missing_payload_copy_no_overwrite_and_source_retention(self):
        self.assertNotIn("replaceItemAt", self.publication)
        self.assertNotIn("removeItem(at: bundleURL)", self.publication)
        self.assertNotIn("removeItem(at: targetFileURL)", self.publication)
        missing = self.publication.index("if !FileManager.default.fileExists(atPath: targetFileURL.path)")
        copy = self.publication.index("copyItem(at: bundleURL, to: targetFileURL, shouldReplace: false)")
        self.assertLess(missing, copy)
        self.assertNotIn("staging", self.publication)
        self.assertNotIn("moveItem", self.publication)

    def test_shared_payload_pruning_is_disabled(self):
        prune = self.cache_source.split("static func pruneUnusedCaches", 1)[1]
        self.assertIn("shared payload auto-pruning is intentionally", prune)
        self.assertNotIn("removeItem(at: payloadDir)", prune)
        self.assertNotIn("DELETING UNUSED CACHED PAYLOAD", prune)

    def test_original_bundle_id_fallback_is_preserved(self):
        source = SOURCE_FILES["InstalledApp.swift"].read_text()
        body = source.split("    var fileURL: URL {\n", 1)[1].split("    var refreshedIPAURL", 1)[0]
        self.assertIn("payloadURL(forSignature: signature)", body)
        self.assertIn("self.directoryURL.appendingPathComponent", body)
        self.assertIn("appendingPathComponent(self.bundleIdentifier)", body)
        self.assertIn("return legacy", body)
        self.assertNotIn("removeItem", body)

    def test_cache_compatibility_key_and_existing_hit_with_containment(self):
        self.assertIn("AppBundleFingerprint.computeOriginalCacheKey(for: bundleURL)", self.publication)
        self.assertNotIn("AppBundleFingerprint.compute(for:", self.publication)
        containment = self.publication.index("guard targetFileURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath)")
        missing = self.publication.index("if !FileManager.default.fileExists(atPath: targetFileURL.path)")
        self.assertLess(containment, missing)
        existing = self.publication.split("} else {", 1)[1].split("return (signature, targetFileURL)", 1)[0]
        self.assertNotIn("copyItem", existing)
        self.assertNotIn("removeItem", existing)
        self.assertNotIn("compute", existing)
        legacy = self.complete_fingerprint_source.split("public static func computeOriginalCacheKey", 1)[1]
        self.assertIn("fileSizeKey", legacy)
        self.assertIn(".skipsHiddenFiles", legacy)



if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__)))
    report = {
        "scope": "Retained strict-cache historical MODEL + current compatibility/strict-host Swift SOURCE contracts only",
        "not_validated": ["Swift compilation", "Darwin/Foundation concurrent publication", "actual iOS app install/refresh", "CoreData reference commits"],
        "tests_run": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "successful": result.wasSuccessful(),
        "source_sha256": {name: hashlib.sha256(SOURCE_FILES[name].read_bytes()).hexdigest() for name in ("AppBundleFingerprint.swift", "CacheAppOperation.swift", "InstalledApp.swift")},
    }
    print(json.dumps(report, indent=2))
    raise SystemExit(not result.wasSuccessful())
