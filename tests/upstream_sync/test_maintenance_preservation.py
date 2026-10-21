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


def digest(path, content_identity=False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        raise ValueError("unsupported symlink")
    prefix = "SideStore-content-v1\n" if content_identity else ""
    h = hashlib.sha256(f"{prefix}mode:{stat.S_IMODE(info.st_mode)}\n".encode())
    if path.is_dir():
        h.update(b"directory\n")
        for item in sorted(path.iterdir(), key=lambda p: p.name):
            name = item.name.encode()
            h.update(f"{len(name)}:".encode())
            h.update(name)
            h.update(digest(item, content_identity))
    elif path.is_file():
        h.update(b"file\n")
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
    else:
        raise ValueError("unsupported file")
    return h.digest()


def copy_preserving(source, target, root, fail=None, expected=None, expected_key=None, hook=None):
    for path in (source, target):
        if not path.resolve().is_relative_to(root.resolve()) or path.resolve() == root.resolve():
            raise ValueError("unsafe path")
    before = digest(source)
    if expected is not None and before != expected:
        raise ValueError("source changed after validation")
    if expected_key is not None and content_key(source) != expected_key:
        raise ValueError("source does not match selected content key")
    if target.exists():
        if digest(target) != before:
            return "conflict"
        if expected_key is not None and content_key(target) != expected_key:
            raise ValueError("existing payload does not match selected content key")
        return "identical"
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
        if hook:
            hook("after_copy", source, stage, target)
        if fail == "corrupt":
            stage.write_bytes(b"corrupt owned scratch data")
        if digest(stage) != before or digest(source) != before:
            raise ValueError("verification failed")
        if expected_key is not None and (content_key(stage) != expected_key or content_key(source) != expected_key):
            raise ValueError("copied snapshot does not match selected content key")
        if fail == "racer":
            target.write_bytes(b"independently-created-target")
        if target.exists():
            if digest(target) != before:
                return "conflict"
            if expected_key is not None and content_key(target) != expected_key:
                raise ValueError("raced payload does not match selected content key")
            return "identical"
        if source.is_dir():
            # Single-writer directory MODEL only. Foundation race behavior is
            # not exercised or claimed by these Python tests.
            stage.rename(target)
        else:
            # Atomic no-replacement publication for model regular files.
            os.link(stage, target)
        if digest(target) != before:
            raise ValueError("promotion verification failed")
        if expected_key is not None and content_key(target) != expected_key:
            raise ValueError("published payload does not match selected content key")
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


def content_key(bundle):
    if not bundle.is_dir() or bundle.is_symlink():
        raise ValueError("unsupported bundle")
    return "content-v1-" + digest(bundle, content_identity=True).hex()


def migrate_bundle_candidates(sources, root, database, hook=None, fail=None):
    """Owned single-writer FS + dictionary model, not Swift/CoreData execution."""
    if database.get("fingerprint") is not None:
        return "retained"
    expected_revision = database.get("revision", 0)
    try:
        snapshots = []
        for source in sorted(sources):
            before = digest(source)
            key = content_key(source)
            if digest(source) != before:
                raise ValueError("unstable candidate")
            snapshots.append((source, before, key))
        source, expected, signature = snapshots[0]
        if not all(item[1:] == snapshots[0][1:] for item in snapshots):
            return "conflict"
        if hook:
            hook("after_selection", source, None, None)
        target = root / "Payloads" / signature / "App.app"
        outcome = copy_preserving(source, target, root, expected=expected,
                                  expected_key=signature, hook=hook, fail=fail)
        if outcome in ("copied", "identical"):
            if hook:
                hook("before_database", source, None, target)
            if not all(digest(path) == before for path, before, _ in snapshots):
                raise ValueError("candidate changed before database reference")
            if content_key(target) != signature:
                raise ValueError("destination changed before database reference")
            if fail == "database_save":
                raise OSError("injected dictionary commit failure, not CoreData")
            if database.get("revision", 0) != expected_revision:
                raise OSError("fake optimistic store conflict, not CoreData")
            database["fingerprint"] = signature
        return outcome
    except (OSError, ValueError):
        return "pending"


class MaintenanceSnapshotRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="owned-maintenance-regression-")
        self.root = Path(self.temp.name)
        self.original = self.root / "original.id" / "App.app"
        self.resigned = self.root / "resigned.id" / "App.app"
        for bundle in (self.original, self.resigned):
            bundle.mkdir(parents=True)
            (bundle / "binary").write_bytes(b"FAKE-A")
        self.database = {}

    def tearDown(self):
        self.temp.cleanup()

    def migrate(self, sources=None, **kwargs):
        return migrate_bundle_candidates(sources or [self.original, self.resigned],
                                         self.root, self.database, **kwargs)

    def test_divergent_original_and_resigned_candidates_never_choose_by_order(self):
        (self.resigned / "binary").write_bytes(b"FAKE-B")
        for sources in ([self.original, self.resigned], [self.resigned, self.original]):
            self.assertEqual(self.migrate(sources), "conflict")
            self.assertEqual(self.database, {})
            self.assertFalse((self.root / "Payloads").exists())
        self.assertEqual((self.original / "binary").read_bytes(), b"FAKE-A")
        self.assertEqual((self.resigned / "binary").read_bytes(), b"FAKE-B")

    def test_identical_candidates_are_order_independent_and_retained(self):
        self.assertEqual(self.migrate([self.resigned, self.original]), "copied")
        first = self.database["fingerprint"]
        self.database.clear()
        self.assertEqual(self.migrate([self.original, self.resigned]), "identical")
        self.assertEqual(self.database["fingerprint"], first)
        self.assertEqual(content_key(self.original), content_key(self.resigned))

    def test_candidate_conflict_is_retryable_after_explicit_resolution(self):
        (self.resigned / "binary").write_bytes(b"FAKE-B")
        self.assertEqual(self.migrate(), "conflict")
        # Simulates explicit resolution by the owner; migration never does this.
        (self.resigned / "binary").write_bytes(b"FAKE-A")
        self.assertEqual(self.migrate(), "copied")

    def test_existing_reference_never_reverted_even_with_legacy_conflict(self):
        self.database["fingerprint"] = "newer-existing-key"
        (self.resigned / "binary").write_bytes(b"FAKE-B")
        self.assertEqual(self.migrate(), "retained")
        self.assertEqual(self.database["fingerprint"], "newer-existing-key")
        self.assertFalse((self.root / "Payloads").exists())

    def test_source_change_between_key_selection_and_copy_never_published(self):
        old_key = content_key(self.original)
        def inject(event, source, stage, target):
            if event == "after_selection":
                (source / "binary").write_bytes(b"FAKE-B")
        self.assertEqual(self.migrate([self.original], hook=inject), "pending")
        self.assertFalse((self.root / "Payloads" / old_key / "App.app").exists())
        self.assertEqual(self.database, {})

    def test_stale_key_rejected_even_if_later_digest_and_copy_would_agree(self):
        old_key = content_key(self.original)
        (self.original / "binary").write_bytes(b"FAKE-B")
        target = self.root / "Payloads" / old_key / "App.app"
        with self.assertRaises(ValueError):
            copy_preserving(self.original, target, self.root,
                            expected=digest(self.original), expected_key=old_key)
        self.assertFalse(target.exists())
        self.assertEqual(self.database, {})

    def test_staged_bytes_and_source_must_match_key_before_publication(self):
        key = content_key(self.original)
        def inject(event, source, stage, target):
            if event == "after_copy":
                (stage / "binary").write_bytes(b"FAKE-B")
                (source / "binary").write_bytes(b"FAKE-B")
        self.assertEqual(self.migrate([self.original], hook=inject), "pending")
        self.assertFalse((self.root / "Payloads" / key / "App.app").exists())
        self.assertEqual(list(self.root.glob("Payloads/*/.preservation-*")), [])
        self.assertEqual(self.database, {})

    def test_unselected_candidate_change_blocks_database_reference(self):
        def inject(event, source, stage, target):
            if event == "before_database":
                (self.resigned / "binary").write_bytes(b"FAKE-B")
        self.assertEqual(self.migrate(hook=inject), "pending")
        self.assertEqual(self.database, {})
        key = content_key(self.original)
        target = self.root / "Payloads" / key / "App.app"
        self.assertEqual(content_key(target), key)
        self.assertTrue(self.original.exists())
        self.assertTrue(self.resigned.exists())

    def test_destination_change_blocks_database_reference(self):
        def inject(event, source, stage, target):
            if event == "before_database":
                (target / "binary").write_bytes(b"FAKE-B")
        self.assertEqual(self.migrate([self.original], hook=inject), "pending")
        self.assertEqual(self.database, {})
        self.assertEqual((self.original / "binary").read_bytes(), b"FAKE-A")

    def test_database_failure_retains_copies_and_retries_idempotently(self):
        self.assertEqual(self.migrate(fail="database_save"), "pending")
        self.assertEqual(self.database, {})
        self.assertTrue(self.original.exists())
        self.assertTrue(self.resigned.exists())
        self.assertEqual(self.migrate(), "identical")
        self.assertEqual(self.database["fingerprint"], content_key(self.original))

    def test_concurrent_newer_reference_causes_save_conflict_without_overwrite(self):
        def inject(event, source, stage, target):
            if event == "before_database":
                # A separate writer commits after the migration's nil snapshot.
                self.database["fingerprint"] = "newer-concurrent-key"
                self.database["revision"] = 1
        self.assertEqual(self.migrate(hook=inject), "pending")
        self.assertEqual(self.database["fingerprint"], "newer-concurrent-key")
        self.assertEqual(self.database["revision"], 1)
        self.assertTrue(self.original.exists())
        self.assertTrue(self.resigned.exists())
        key = content_key(self.original)
        self.assertEqual(content_key(self.root / "Payloads" / key / "App.app"), key)
        self.assertEqual(self.migrate(), "retained")
        self.assertEqual(self.database["fingerprint"], "newer-concurrent-key")

    def test_copy_failure_retains_originals_and_retries(self):
        self.assertEqual(self.migrate(fail="copy"), "pending")
        self.assertEqual(self.database, {})
        self.assertEqual(self.migrate(), "copied")
        self.assertEqual(content_key(self.original), content_key(self.resigned))


class PairingImportSelectionRegressionTests(unittest.TestCase):
    """Opaque fake protocol records; no pairing parser, credentials or device use."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="owned-pairing-selection-")
        self.root = Path(self.temp.name)
        (self.root / "legacy").write_text("FAKE old record")
        self.preferences = {"preferred": None, "persisted": None}

    def tearDown(self):
        self.temp.cleanup()

    def fetch(self):
        for selected in (self.preferences["preferred"], self.preferences["persisted"]):
            if selected and (self.root / selected).exists():
                return (self.root / selected).read_text()
        return (self.root / "legacy").read_text()

    def explicit_import(self, content, parsed_mode, preferred=None, fail=None):
        requested = preferred or self.preferences["preferred"]
        if requested is not None and requested != parsed_mode:
            raise ValueError("explicit import guard rejects parser mode mismatch before write")
        if fail == "write":
            raise OSError("fake atomic write failure")
        destination = self.root / parsed_mode
        destination.write_text(content)
        if fail == "readback":
            raise OSError("fake readback failure")
        if destination.read_text() != content:
            raise ValueError("readback mismatch")
        self.preferences["persisted"] = parsed_mode

    def test_host_import_outranks_retained_legacy_on_next_fetch(self):
        self.explicit_import("FAKE new remote", "remote")
        self.assertEqual(self.fetch(), "FAKE new remote")
        self.assertEqual((self.root / "legacy").read_text(), "FAKE old record")

    def test_failed_write_does_not_activate_or_remove_old_files(self):
        self.preferences["persisted"] = "lockdown"
        (self.root / "lockdown").write_text("FAKE selected record")
        with self.assertRaises(OSError):
            self.explicit_import("FAKE new remote", "remote", fail="write")
        self.assertEqual(self.preferences["persisted"], "lockdown")
        self.assertEqual(self.fetch(), "FAKE selected record")
        self.assertFalse((self.root / "remote").exists())

    def test_failed_readback_does_not_claim_selected_protocol(self):
        with self.assertRaises(OSError):
            self.explicit_import("FAKE new remote", "remote", fail="readback")
        self.assertIsNone(self.preferences["persisted"])
        self.assertEqual((self.root / "legacy").read_text(), "FAKE old record")

    def test_explicit_preferred_selection_not_silently_overridden(self):
        self.preferences["preferred"] = "lockdown"
        (self.root / "lockdown").write_text("FAKE selected record")
        with self.assertRaises(ValueError):
            self.explicit_import("FAKE new remote", "remote")
        self.assertEqual(self.preferences["preferred"], "lockdown")
        self.assertEqual(self.fetch(), "FAKE selected record")
        self.assertFalse((self.root / "remote").exists())

    def test_import_matching_preferred_keeps_that_preference(self):
        self.preferences["preferred"] = "remote"
        self.explicit_import("FAKE new remote", "remote")
        self.assertEqual(self.preferences, {"preferred": "remote", "persisted": "remote"})
        self.assertEqual(self.fetch(), "FAKE new remote")


class PreservationRegressionSourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.maintenance = SOURCE.read_text()
        cls.migration = cls.maintenance.split("func migrateLegacyCachedAppBundles()", 1)[1].split(
            "func migrateLegacyCachedSigningCertificates()", 1)[0]
        cls.copy = cls.maintenance.split("func copyPreservingOriginal(", 1)[1].split(
            "/// Content-and-structure digest", 1)[0]
        cls.pairing = (REPO_ROOT / "SideStore/Core/Pairing/PairingFileManager.swift").read_text()
        cls.host = (REPO_ROOT / "AltStore/AppDelegate.swift").read_text()

    def test_all_candidates_are_grouped_before_any_reference_assignment(self):
        self.assertIn("var sourcesByAppID: [NSManagedObjectID: [URL]]", self.migration)
        self.assertIn("matches.count == 1", self.migration)
        grouped = self.migration.index("sourcesByAppID[app.objectID, default: []].append(source)")
        migration = self.migration.index("for app in installedApps {", grouped)
        agreement = self.migration.index("snapshots.allSatisfy({ $0.digest == snapshot.digest && $0.signature == snapshot.signature })")
        assignment = self.migration.index("app.appBundleFingerprint = signature")
        self.assertLess(grouped, migration)
        self.assertLess(migration, agreement)
        self.assertLess(agreement, assignment)
        self.assertIn("outcomes.conflict += 1", self.migration[agreement:assignment])

    def test_optimistic_conflicts_fail_closed_in_only_the_payload_migration_context(self):
        entered = self.migration.index("context.perform {")
        policy = self.migration.index("context.mergePolicy = NSErrorMergePolicy")
        fetched = self.migration.index("context.fetch(InstalledApp.fetchRequest())")
        saved = self.migration.index("try context.save()")
        rolled_back = self.migration.index("context.rollback()")
        self.assertLess(entered, policy)
        self.assertLess(policy, fetched)
        self.assertLess(fetched, saved)
        self.assertLess(saved, rolled_back)
        self.assertEqual(self.maintenance.count("context.mergePolicy = NSErrorMergePolicy"), 1)
        certificates = self.maintenance.split("func migrateLegacyCachedSigningCertificates()", 1)[1].split(
            "func migratePairingFiles()", 1)[0]
        self.assertNotIn("mergePolicy", certificates)

    def test_copy_binds_stage_to_key_before_move_and_destination_before_success(self):
        self.assertIn("expectedDigest: snapshot.digest, expectedFingerprint: signature", self.migration)
        staged = self.copy.index("AppBundleFingerprint.compute(for: staging) == expectedFingerprint")
        move = self.copy.index("fm.moveItem(at: staging, to: destination)")
        self.assertLess(staged, move)
        self.assertIn("AppBundleFingerprint.compute(for: source) == expectedFingerprint", self.copy[:move])
        self.assertIn("AppBundleFingerprint.compute(for: destination) != expectedFingerprint", self.copy[move:])
        self.assertGreaterEqual(self.copy.count("AppBundleFingerprint.compute(for: destination) != expectedFingerprint"), 3)

    def test_all_sources_and_published_key_rechecked_before_database_reference(self):
        assignment = self.migration.index("app.appBundleFingerprint = signature")
        self.assertIn("snapshots.allSatisfy({ try self.exactDigest(of: $0.source) == $0.digest })", self.migration[:assignment])
        self.assertIn("AppBundleFingerprint.compute(for: destination) == signature", self.migration[:assignment])
        self.assertIn("context.rollback()", self.migration)

    def test_host_and_url_import_share_explicit_activation_not_ordinary_save(self):
        host = self.host.split("static func pairingImportData(token:", 1)[1].split("static func pairingFileStatus", 1)[0]
        self.assertIn("PairingFileManager.shared.importPairingFile(contents: contents)", host)
        self.assertNotIn("savePairingFile(contents:", host)
        ordinary = self.pairing.split("func savePairingFile(contents:", 1)[1].split("func inspectPairingFile", 1)[0]
        self.assertNotIn("persistedActiveProtocol =", ordinary)
        explicit = self.pairing.split("func importPairingFile(contents:", 1)[1].split("func importPairingFile(from", 1)[0]
        self.assertIn("let selectedProtocol = preferred ?? preferredProtocol", explicit)
        inspected = explicit.index("try parse(content: contents, preferred: selectedProtocol)")
        mismatch = explicit.index("if let selectedProtocol, inspected.mode != selectedProtocol")
        saved = explicit.index("try savePairingFile(")
        checked = explicit.index("fetchPairingFile(for: parsed.mode) == contents")
        activate = explicit.index("persistedActiveProtocol = parsed.mode")
        self.assertLess(inspected, mismatch)
        self.assertLess(mismatch, saved)
        self.assertIn("throw CocoaError(.fileReadCorruptFile)", explicit[mismatch:saved])
        self.assertIn("parsed.mode == inspected.mode", explicit[saved:checked])
        self.assertLess(saved, checked)
        self.assertLess(checked, activate)
        self.assertNotIn("preferredProtocol =", explicit)
        url_import = self.pairing.split("func importPairingFile(from", 1)[1].split("func deletePairingFile", 1)[0]
        self.assertIn("try importPairingFile(contents: content, preferred: preferred)", url_import)

    def test_maintenance_does_not_select_pairing_or_add_tombstone_scope(self):
        for forbidden in ("persistedActiveProtocol =", "preferredProtocol =", "isPairingReset =", "tombstone"):
            self.assertNotIn(forbidden, self.maintenance)
        fetch = self.pairing.split("func fetchPairingFile(preferred:", 1)[1].split("func parse(content:", 1)[0]
        self.assertLess(fetch.index("preferred ?? preferredProtocol"), fetch.index("persistedActiveProtocol"))
        self.assertLess(fetch.index("persistedActiveProtocol"), fetch.index("if let legacy = fetchPairingFile(for: .unknown) { return legacy }"))


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
