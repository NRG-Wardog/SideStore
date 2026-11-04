"""Portable production wiring guards; real Core Data behavior requires macOS CI."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'AltStore/Core/Model/DatabaseManager/PersistentContainer.swift'

def assert_schema_guard_contract(check, text):
    boundaries = [
        ('    private func validateMigrationCompatibility(', '    open override func newBackgroundContext()', 'metadata'),
        ('    private func _progressivelyMigratePersistentStore(', '    private func sourceModel(', 'sourceMetadata'),
    ]
    for begin, end, metadata in boundaries:
        check.assertEqual(text.count(begin), 1)
        body = text.split(begin, 1)[1].split(end, 1)[0]
        unknown = body.split('guard let sourceModel = self.sourceModel(forStoreMetadata: '+metadata+') else {', 1)[1].split('var mappingModel:', 1)[0]
        check.assertEqual(unknown.count('cause: .databaseModelUnrecognized'), 1)
        check.assertIn('underlying: DatabaseError.databaseDowngradeDetected(', unknown)
        check.assertEqual(body.count('cause: .databaseMigrationPathUnavailable'), 1)
        check.assertIn('self.progressiveMigrationManager(forSourceModel: sourceModel', body)
    recovery = text.split('    func validateRecoveryStore(', 1)[1].split('    private func validateMigrationCompatibility(', 1)[0]
    guard = 'guard let source = sourceModel(forStoreMetadata: metadata),'
    check.assertLess(recovery.index('if migrateStagedCopy {'), recovery.index(guard))
    check.assertIn('!source.entities.flatMap({ $0.attributesByName.values }).contains(where: { $0.allowsExternalBinaryDataStorage }) else {', recovery)
    check.assertEqual(recovery.count('cause: .databaseModelUnrecognized'), 1)
    check.assertIn('underlying: DatabaseError.migrationFailed(reason: "The previous database model or its external data cannot be safely recovered. The original remains intact.")', recovery)
    check.assertLess(recovery.index('cause: .databaseModelUnrecognized'), recovery.index('description.url = url'))
    check.assertIn('defer { description.url = originalURL }', recovery)
    check.assertIn('NSReadOnlyPersistentStoreOption: true', recovery)
    for mutation in ('destroyPersistentStore', 'removeItem', 'copyItem'):
        check.assertNotIn(mutation, recovery)
    # The two prior rejection sites remain, plus the staged-recovery rejection.
    check.assertEqual(text.count('cause: .databaseModelUnrecognized'), 3)
    check.assertEqual(text.count('cause: .databaseMigrationPathUnavailable'), 2)

class ModelResourceOwnerTests(unittest.TestCase):
    def setUp(self):
        self.text = SOURCE.read_text()

    def test_explicit_resource_owner_retained_before_super(self):
        body = self.text.split('public init(name: String, bundle: Bundle) {', 1)[1].split('private func initialize()', 1)[0]
        self.assertLess(body.index('self.modelResourceBundle = bundle'), body.index('super.init'))
        self.assertIn('NSManagedObjectModel.mergedModel(from: models)', body)
        self.assertIn('self.modelResourceBundle = nil', body)
        self.assertIn('private let modelResourceBundle: Bundle?', self.text)

    def test_source_lookup_uses_metadata_and_preserves_original_fallback(self):
        body = self.text.split('private func sourceModel(', 1)[1].split('private func modelLookupBundles()', 1)[0]
        self.assertIn('mergedModel(from: [bundle], forStoreMetadata: metadata)', body)
        self.assertIn('return NSManagedObjectModel.mergedModel(from: Bundle.allBundles, forStoreMetadata: metadata)', body)
        self.assertNotIn('self.managedObjectModel', body)
        self.assertNotIn('inferredMappingModel', body)
        self.assertIn('self.sourceModel(forStoreMetadata: metadata)', self.text)
        self.assertIn('self.sourceModel(forStoreMetadata: sourceMetadata)', self.text)

    def test_mapping_resource_lookup_adds_only_owned_bundle(self):
        body = self.text.split('private func modelLookupBundles()', 1)[1].split('private func progressiveMigrationManager(', 1)[0]
        self.assertIn('self.modelResourceBundle.map { [$0] } ?? []', body)
        self.assertIn('(candidates + Bundle.allBundles).filter', body)
        self.assertIn('seen.insert($0.bundleURL.resolvingSymlinksInPath()).inserted', body)
        self.assertIn('for bundle in self.modelLookupBundles()', self.text)
        self.assertIn('NSMappingModel(from: self.modelLookupBundles()', self.text)
        self.assertNotIn('Bundle.allFrameworks', self.text)

    def test_unknown_schema_and_unavailable_mapping_still_rejected(self):
        assert_schema_guard_contract(self, self.text)
        body = self.text.split('private func sourceModel(', 1)[1].split('@objc private func managedObjectContextWillSave', 1)[0]
        for mutation in ('replacePersistentStore', 'destroyPersistentStore', 'removeItem', 'copyItem'):
            self.assertNotIn(mutation, body)

    def test_schema_guard_contract_rejects_missing_or_wrong_boundaries(self):
        tokens = [
            ('cause: .databaseModelUnrecognized', 'cause: .databaseStartupFailed'),
            ('cause: .databaseMigrationPathUnavailable', 'cause: .databaseStartupFailed'),
        ]
        for before, after in tokens:
            positions = [i for i in range(len(self.text)) if self.text.startswith(before, i)]
            for index in positions:
                changed = self.text[:index]+self.text[index:].replace(before, after, 1)
                with self.subTest(token=before, index=index), self.assertRaises(AssertionError):
                    assert_schema_guard_contract(self, changed)
                missing = self.text[:index]+self.text[index:].replace(before, '', 1)
                with self.subTest(missing=before, index=index), self.assertRaises(AssertionError):
                    assert_schema_guard_contract(self, missing)
        for before, after in [
            ('if migrateStagedCopy {', 'if true {'),
            ('!source.entities.flatMap', 'source.entities.flatMap'),
            ('defer { description.url = originalURL }', ''),
        ]:
            self.assertEqual(self.text.count(before), 1)
            with self.subTest(guard=before), self.assertRaises((AssertionError, ValueError)):
                assert_schema_guard_contract(self, self.text.replace(before, after, 1))

if __name__ == '__main__':
    unittest.main()
