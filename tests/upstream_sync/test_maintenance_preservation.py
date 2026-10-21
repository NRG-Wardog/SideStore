"""Owned fake-filesystem MODEL tests and Swift SOURCE contract checks.

These tests deliberately do not execute Swift, CoreData, SQLite, minimuxer,
cryptography/authentication libraries, or device pairing. They validate the
expected algorithm against fake files and bind key invariants to the candidate
source. They are NOT iOS integration or CoreData migration tests.
"""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import stat
import tempfile
import unittest
import uuid

# In-repository default: tests/upstream_sync/../../ is the repository root.
# An explicit override supports reviewing an assembled tree before publication.
REPO_ROOT = Path(os.environ.get("PRESERVATION_REPO_ROOT", str(Path(__file__).resolve().parents[2])))
SOURCE = REPO_ROOT / "SideStore/MaintenanceManager.swift"
REMOTE_KEYS = ("private_key", "public_key", "identifier")
LOCKDOWN_KEYS = ("WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey",
                 "HostID", "RootCertificate", "UDID", "EscrowBag", "HostCertificate", "DeviceCertificate")


def digest(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        raise ValueError("unsupported symlink")
    h = hashlib.sha256(f"mode:{stat.S_IMODE(info.st_mode)}\n".encode())
    if path.is_dir():
        h.update(b"directory\n")
        for item in sorted(path.iterdir(), key=lambda p: p.name):
            name = item.name.encode()
            h.update(f"{len(name)}:".encode())
            h.update(name)
            h.update(digest(item))
    elif path.is_file():
        h.update(b"file\n")
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
    else:
        raise ValueError("unsupported file")
    return h.digest()


def copy_preserving(source, target, root, fail=None, expected=None):
    for path in (source, target):
        if not path.resolve().is_relative_to(root.resolve()) or path.resolve() == root.resolve():
            raise ValueError("unsafe path")
    before = digest(source)
    if expected is not None and before != expected:
        raise ValueError("source changed after validation")
    if target.exists():
        return "identical" if digest(target) == before else "conflict"
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = target.parent / (".preservation-" + str(uuid.uuid4()))
    try:
        if fail == "copy":
            stage.write_bytes(b"partial owned scratch data")
            raise OSError("injected copy failure")
        if source.is_dir():
            shutil.copytree(source, stage)
        else:
            shutil.copy2(source, stage)
        if fail == "corrupt":
            stage.write_bytes(b"corrupt owned scratch data")
        if digest(stage) != before or digest(source) != before:
            raise ValueError("verification failed")
        if fail == "racer":
            target.write_bytes(b"independently-created-target")
        if target.exists():
            return "identical" if digest(target) == before else "conflict"
        if source.is_dir():
            # Single-writer directory MODEL only. Foundation race behavior is
            # not exercised or claimed by these Python tests.
            stage.rename(target)
        else:
            # Atomic no-replacement publication for model regular files.
            os.link(stage, target)
        if digest(target) != before:
            raise ValueError("promotion verification failed")
        return "copied"
    finally:
        if stage.exists():
            if stage.is_dir():
                shutil.rmtree(stage)
            else:
                stage.unlink()


def migrate_pairing(source, root, fail=None):
    if not source.exists():
        return {"absent": 1}
    validated = digest(source)
    try:
        payload = plistlib.loads(source.read_bytes())
    except Exception:
        return {"pending": 1}
    if not isinstance(payload, dict):
        return {"pending": 1}
    result = {}
    for keys, name in ((REMOTE_KEYS, "remote.plist"), (LOCKDOWN_KEYS, "lockdown.plist")):
        if all(key in payload for key in keys):
            try:
                outcome = copy_preserving(source, root / name, root, fail=fail, expected=validated)
            except (OSError, ValueError):
                outcome = "pending"
            result[name] = outcome
    return result or {"pending": 1}


def choose_database(shared, private, old_apps, requires_migration=False):
    names = ("AltStore.sqlite", "SideStore.sqlite")
    suffixes = ("", "-wal", "-shm")
    if private.resolve() != shared.resolve():
        if any((private / (name + suffix)).exists() for name in names for suffix in suffixes):
            raise ValueError("previous private layout")
    shared_apps = shared.parent / "Apps"
    if requires_migration and old_apps.resolve() != shared_apps.resolve() and old_apps.exists() and any(old_apps.iterdir()):
        raise ValueError("pending private app data")
    legacy, current = (shared / name for name in names)
    for file in (legacy, current):
        if not file.exists() and any(Path(str(file) + suffix).exists() for suffix in suffixes[1:]):
            raise ValueError("orphaned sidecars")
    if legacy.exists() and current.exists():
        raise ValueError("ambiguous layouts")
    chosen = legacy if legacy.exists() else current
    if chosen.exists() and (not chosen.is_file() or chosen.is_symlink()):
        raise ValueError("not a regular store")
    return chosen


class PreservationModelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="owned-preservation-fixtures-")
        self.root = Path(self.tmp.name)
        self.source = self.root / "legacy.bin"
        self.target = self.root / "new" / "target.bin"
        self.source.write_bytes(b"FAKE test material, not credentials")

    def tearDown(self):
        self.tmp.cleanup()

    def test_identical_target_retains_both_and_does_not_rewrite(self):
        self.target.parent.mkdir()
        shutil.copy2(self.source, self.target)
        source_stat, target_stat = self.source.stat(), self.target.stat()
        self.assertEqual(copy_preserving(self.source, self.target, self.root), "identical")
        self.assertEqual(self.source.stat(), source_stat)
        self.assertEqual(self.target.stat(), target_stat)

    def test_equal_length_different_bytes_are_conflict(self):
        self.source.write_bytes(b"AAAA")
        self.target.parent.mkdir()
        self.target.write_bytes(b"BBBB")
        self.assertEqual(copy_preserving(self.source, self.target, self.root), "conflict")
        self.assertEqual(self.source.read_bytes(), b"AAAA")
        self.assertEqual(self.target.read_bytes(), b"BBBB")

    def test_failed_copy_is_retryable_and_preserves_original(self):
        before = self.source.read_bytes()
        with self.assertRaises(OSError):
            copy_preserving(self.source, self.target, self.root, fail="copy")
        self.assertEqual(self.source.read_bytes(), before)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.glob(".preservation-*")), [])
        self.assertEqual(copy_preserving(self.source, self.target, self.root), "copied")
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(self.source.read_bytes(), before)

    def test_staging_corruption_not_published(self):
        before = self.source.read_bytes()
        with self.assertRaises(ValueError):
            copy_preserving(self.source, self.target, self.root, fail="corrupt")
        self.assertEqual(self.source.read_bytes(), before)
        self.assertFalse(self.target.exists())

    def test_concurrently_created_target_not_overwritten(self):
        before = self.source.read_bytes()
        self.assertEqual(copy_preserving(self.source, self.target, self.root, fail="racer"), "conflict")
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(self.target.read_bytes(), b"independently-created-target")

    def test_idempotent_retry_does_not_rewrite(self):
        self.assertEqual(copy_preserving(self.source, self.target, self.root), "copied")
        old = self.target.stat()
        self.assertEqual(copy_preserving(self.source, self.target, self.root), "identical")
        self.assertEqual(old, self.target.stat())
        self.assertTrue(self.source.exists())

    def test_hidden_bundle_contents_are_verified(self):
        self.source.unlink()
        self.source.mkdir()
        (self.source / "binary").write_bytes(b"same-size-A")
        (self.source / ".hidden").write_bytes(b"A")
        self.target.parent.mkdir()
        shutil.copytree(self.source, self.target)
        (self.target / ".hidden").write_bytes(b"B")
        self.assertEqual(copy_preserving(self.source, self.target, self.root), "conflict")

    def test_symlink_source_is_not_copied(self):
        target = self.root / "other-owned-fixture"
        target.write_bytes(b"unchanged")
        self.source.unlink()
        self.source.symlink_to(target)
        with self.assertRaises(ValueError):
            copy_preserving(self.source, self.target, self.root)
        self.assertEqual(target.read_bytes(), b"unchanged")
        self.assertFalse(self.target.exists())

    def test_source_change_after_parse_is_rejected(self):
        previous = digest(self.source)
        self.source.write_bytes(b"different owned fixture")
        with self.assertRaises(ValueError):
            copy_preserving(self.source, self.target, self.root, expected=previous)
        self.assertFalse(self.target.exists())

    def test_malformed_pairing_is_retained(self):
        before = self.source.read_bytes()
        self.assertEqual(migrate_pairing(self.source, self.root), {"pending": 1})
        self.assertEqual(self.source.read_bytes(), before)
        self.assertFalse((self.root / "remote.plist").exists())
        self.assertFalse((self.root / "lockdown.plist").exists())

    def test_dual_protocol_pairing_preserves_exact_original(self):
        data = plistlib.dumps({key: "FAKE" for key in REMOTE_KEYS + LOCKDOWN_KEYS})
        self.source.write_bytes(data)
        result = migrate_pairing(self.source, self.root)
        self.assertEqual(result, {"remote.plist": "copied", "lockdown.plist": "copied"})
        for path in (self.source, self.root / "remote.plist", self.root / "lockdown.plist"):
            self.assertEqual(path.read_bytes(), data)

    def test_pairing_failed_copy_preserves_source_and_retries(self):
        data = plistlib.dumps({key: "FAKE" for key in REMOTE_KEYS})
        self.source.write_bytes(data)
        self.assertEqual(migrate_pairing(self.source, self.root, fail="copy"), {"remote.plist": "pending"})
        self.assertEqual(self.source.read_bytes(), data)
        self.assertEqual(migrate_pairing(self.source, self.root), {"remote.plist": "copied"})

    def test_pairing_conflict_is_not_deleted_or_overwritten(self):
        data = plistlib.dumps({key: "FAKE" for key in REMOTE_KEYS})
        self.source.write_bytes(data)
        target = self.root / "remote.plist"
        target.write_bytes(b"existing target")
        self.assertEqual(migrate_pairing(self.source, self.root), {"remote.plist": "conflict"})
        self.assertEqual(self.source.read_bytes(), data)
        self.assertEqual(target.read_bytes(), b"existing target")

    def test_missing_legacy_counter_does_not_reset_or_create_counter(self):
        counter = self.root / ".maintenance_counter"
        self.assertFalse(counter.exists())
        before = self.source.read_bytes()
        copy_preserving(self.source, self.target, self.root)
        self.assertFalse(counter.exists())
        self.assertEqual(self.source.read_bytes(), before)

    def test_malformed_legacy_counter_is_unchanged(self):
        counter = self.root / ".maintenance_counter"
        counter.write_bytes(b"not a maintenance number")
        copy_preserving(self.source, self.target, self.root)
        self.assertEqual(counter.read_bytes(), b"not a maintenance number")


class DatabaseModelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="owned-store-layout-fixtures-")
        self.root = Path(self.tmp.name)
        self.shared = self.root / "shared" / "Database"
        self.private = self.root / "private"
        self.apps = self.root / "privateApps"
        for directory in (self.shared, self.private, self.apps):
            directory.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def choose(self, pending=False):
        return choose_database(self.shared, self.private, self.apps, pending)

    def test_legacy_with_wal_is_selected_without_mutation(self):
        for suffix in ("", "-wal", "-shm"):
            (self.shared / ("AltStore.sqlite" + suffix)).write_bytes(b"FAKE-not-SQLite" + suffix.encode())
        before = {p: p.read_bytes() for p in self.shared.iterdir()}
        self.assertEqual(self.choose().name, "AltStore.sqlite")
        self.assertEqual(before, {p: p.read_bytes() for p in self.shared.iterdir()})

    def test_current_store_is_selected(self):
        (self.shared / "SideStore.sqlite").write_bytes(b"fake")
        self.assertEqual(self.choose().name, "SideStore.sqlite")

    def test_both_store_names_fail_closed(self):
        for name in ("AltStore.sqlite", "SideStore.sqlite"):
            (self.shared / name).write_bytes(b"fake")
        before = {p: p.read_bytes() for p in self.shared.iterdir()}
        with self.assertRaises(ValueError): self.choose()
        self.assertEqual(before, {p: p.read_bytes() for p in self.shared.iterdir()})

    def test_orphan_wal_fails_closed(self):
        (self.shared / "AltStore.sqlite-wal").write_bytes(b"fake")
        with self.assertRaises(ValueError): self.choose()
        self.assertFalse((self.shared / "SideStore.sqlite").exists())

    def test_fresh_install_selects_but_does_not_create_store(self):
        self.assertEqual(self.choose().name, "SideStore.sqlite")
        self.assertEqual(list(self.shared.iterdir()), [])

    def test_private_database_blocks_fresh_shared_store(self):
        (self.private / "AltStore.sqlite").write_bytes(b"fake")
        with self.assertRaises(ValueError): self.choose()
        self.assertEqual(list(self.shared.iterdir()), [])

    def test_private_sidecar_alone_blocks_fresh_shared_store(self):
        (self.private / "SideStore.sqlite-wal").write_bytes(b"fake")
        with self.assertRaises(ValueError): self.choose()

    def test_pending_private_app_data_blocks(self):
        (self.apps / "fake.app").mkdir()
        with self.assertRaises(ValueError): self.choose(pending=True)

    def test_empty_pending_default_does_not_block_fresh_install(self):
        self.assertEqual(self.choose(pending=True).name, "SideStore.sqlite")
        self.assertEqual(list(self.shared.iterdir()), [])


class SwiftSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()

    def test_no_reset_or_legacy_counter_advancement(self):
        for prohibited in ("Keychain.shared.clearAll", "signOut(", "resetToDefaults(",
                           "AnisetteDataManager.shared.clearCache", "tunnelOverridePeerIp =", "completedCounter ="):
            self.assertNotIn(prohibited, self.source)
        self.assertIn("excludedLegacyPasses = [1, 2, 3, 6]", self.source)
        self.assertIn("legacyCounterUnchanged = true", self.source)

    def test_database_selection_never_copies_or_moves_database(self):
        body = self.source.split("public func preparePersistentStoreURLs", 1)[1].split("public func performMaintenanceIfNeeded", 1)[0]
        for prohibited in ("copyItem(", "moveItem(", "removeItem(", "destroyPersistentStore", "replacePersistentStore"):
            self.assertNotIn(prohibited, body)
        self.assertIn("NSPersistentContainer.defaultDirectoryURL()", body)
        self.assertIn('bool(forKey: "requiresAppGroupMigration")', body)
        self.assertIn("description.url = selected", body)

    def test_cleanup_only_owned_staging_copy(self):
        lines = [line.strip() for line in self.source.splitlines() if "removeItem(" in line]
        self.assertEqual(lines, ["defer { try? fm.removeItem(at: staging) } // Only this invocation's scratch copy."])
        self.assertIn("fm.copyItem(at: source, to: staging)", self.source)
        self.assertIn("fm.moveItem(at: staging, to: destination)", self.source)

    def test_existing_newer_payload_reference_is_not_reverted(self):
        self.assertIn("guard app.appBundleFingerprint == nil", self.source)
        self.assertNotIn("app.appBundleFingerprint = nil", self.source)
        self.assertIn("retainedExistingReference", self.source)

    def test_copy_verifies_real_contents_and_validated_pairing_snapshot(self):
        self.assertIn("FileHandle(forReadingFrom: url)", self.source)
        self.assertIn("hasher.update(data: chunk)", self.source)
        self.assertIn("options: []", self.source)
        self.assertIn("expectedDigest: validatedDigest", self.source)
        self.assertIn("before != expectedDigest", self.source)

    def test_raw_errors_not_logged(self):
        for line in self.source.splitlines():
            if "debugLog(" in line:
                self.assertNotIn("\\(error)", line)
                self.assertNotIn("\\(source)", line)
                self.assertNotIn("\\(content)", line)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {
        "scope": "Owned fake-filesystem algorithm MODEL + Swift SOURCE contracts only",
        "not_validated": ["Swift typechecking", "CoreData", "SQLite/WAL runtime", "iOS filesystem concurrency", "device pairing/authentication"],
        "tests_run": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "successful": result.wasSuccessful(),
        "candidate_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "test_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    print(json.dumps(report, indent=2))
    raise SystemExit(not result.wasSuccessful())
