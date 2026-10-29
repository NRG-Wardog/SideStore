"""Portable production wiring guards; real Core Data behavior requires macOS CI."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'AltStore/Core/Model/DatabaseManager/PersistentContainer.swift'

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
        self.assertEqual(self.text.count('cause: .databaseModelUnrecognized'), 2)
        self.assertEqual(self.text.count('cause: .databaseMigrationPathUnavailable'), 2)
        body = self.text.split('private func sourceModel(', 1)[1].split('@objc private func managedObjectContextWillSave', 1)[0]
        for mutation in ('replacePersistentStore', 'destroyPersistentStore', 'removeItem', 'copyItem'):
            self.assertNotIn(mutation, body)

if __name__ == '__main__':
    unittest.main()
