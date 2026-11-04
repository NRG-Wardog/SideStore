"""Portable source/integration contracts. These do not replace native execution."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class RecoveryIntegration(unittest.TestCase):
    def setUp(self):
        self.engine = (ROOT/'SideStore/DatabaseRecovery.swift').read_text()
        self.maintenance = (ROOT/'SideStore/MaintenanceManager.swift').read_text()
        self.container = (ROOT/'AltStore/Core/Model/DatabaseManager/PersistentContainer.swift').read_text()

    def test_recovery_precedes_open_and_retains_original_locks(self):
        start = (ROOT/'AltStore/Core/Model/DatabaseManager/DatabaseManager.swift').read_text().split('private func performStart()', 1)[1]
        self.assertLess(start.index('preparePersistentStoreURLs'), start.index('loadPersistentStores()'))
        self.assertIn('recoveredSelection = selection', self.maintenance)
        self.assertIn('if let retained = lock.withLock({ recoveredSelection })', self.maintenance)
        self.assertIn('retained.database, migrateStagedCopy: false', self.maintenance)
        self.assertIn('description.url = retained.database', self.maintenance)
        self.assertIn('MaintenanceManager.shared.recoveredAppsDirectory', (ROOT/'AltStore/Core/Model/InstalledApp.swift').read_text())

    def test_no_raw_copy_or_hash_of_original_sqlite(self):
        self.assertIn('sqlite3_backup_init', self.engine)
        self.assertIn('"BEGIN IMMEDIATE"', self.engine)
        self.assertIn('disableCloseCheckpoint(writer)', self.engine)
        self.assertNotIn('digest(candidate.url)', self.engine)
        self.assertNotIn('copyItem(at: candidate.url', self.engine)
        self.assertNotIn('removeItem(at: candidate.url', self.engine)
        self.assertNotIn('SQLITE_OPEN_EXCLUSIVE', self.engine)
        self.assertIn('O_EXCL | O_NOFOLLOW', self.engine)
        self.assertIn('SQLITE_OPEN_PRIVATECACHE', self.engine)

    def test_atomic_generation_and_receipt_include_apps(self):
        self.assertIn('renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, generation.path, UInt32(RENAME_EXCL))', self.engine)
        self.assertIn('receipt.sources == sources', self.engine)
        self.assertIn('receipt.apps == appInventories', self.engine)
        self.assertIn('try validate(database, false) == receipt.storeIdentity', self.engine)
        self.assertIn('try validate(database, true)', self.engine)
        self.assertIn('sources.map(\\.snapshot)', self.engine)
        self.assertIn('"-journal"', self.engine)

    def test_only_staged_copy_can_schema_migrate(self):
        body = self.container.split('func validateRecoveryStore(', 1)[1].split('private func validateMigrationCompatibility(', 1)[0]
        self.assertIn('if migrateStagedCopy {', body)
        self.assertIn('defer { description.url = originalURL }', body)
        self.assertIn('NSReadOnlyPersistentStoreOption: true', body)
        self.assertIn('allowsExternalBinaryDataStorage', body)
        self.assertNotIn('destroyPersistentStore', body)
        self.assertNotIn('deleteDatabase', body)
        self.assertIn('NSStoreUUIDKey', body)

    def test_legacy_reset_cannot_destroy_recovered_generation(self):
        source = (ROOT/'AltStore/Core/Model/DatabaseManager/DatabaseManager.swift').read_text()
        delete = source.split('public class func deleteDatabase()', 1)[1].split('public class func recreateDatabase()', 1)[0]
        self.assertLess(delete.index('performDatabaseResetIfSafe'), delete.index('destroyPersistentStore'))
        self.assertIn('guard !hasRecoveredDatabase else', self.maintenance)
        self.assertGreaterEqual(self.maintenance.count('databaseOwnershipLock.lock()'), 2)
        self.assertIn('guard Self.deleteDatabase() else { return }', source)
        self.assertIn('DatabaseRecovery.withResetLock', self.maintenance)
        self.assertIn('root.appendingPathComponent(startupLockName)', self.engine)
        self.assertIn('container.persistentStoreDescriptions.first?.url', delete)

    def test_native_coredata_runner_compiles_whole_production_container(self):
        source = (ROOT/'tests/database_recovery_coredata/run.py').read_text()
        self.assertIn("ROOT/'AltStore/Core/Model/DatabaseManager/PersistentContainer.swift'", source)
        self.assertIn("ROOT/'SideStore/DatabaseRecovery.swift'", source)
        self.assertIn("for mode in ('delete', 'wal'):", source)
        self.assertIn('original_persistent_bytes_unchanged', source)

if __name__ == '__main__':
    unittest.main()
