import Foundation
import CoreData
import ObjectiveC
import Darwin

func require(_ value: @autoclosure () -> Bool, _ message: String, code: Int = 1) throws {
    if !value() { throw NSError(domain: "SchemaQualification", code: code, userInfo: [NSLocalizedDescriptionKey: message]) }
}

// These generic classes intentionally do not execute application/keychain logic.
func registerFixtureClasses(_ model: NSManagedObjectModel) {
    for entity in model.entities {
        guard let name = entity.managedObjectClassName, NSClassFromString(name) == nil else { continue }
        if let type = objc_allocateClassPair(NSManagedObject.self, name, 0) { objc_registerClassPair(type) }
    }
}

let testedEntities = ["Account", "Team", "InstalledApp", "InstalledExtension"]
func loadModel(_ directory: URL, _ version: String) throws -> NSManagedObjectModel {
    guard let model = NSManagedObjectModel(contentsOf: directory.appendingPathComponent("AltStore \(version).mom")) else {
        throw NSError(domain: "SchemaQualification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Compiled original model missing"])
    }
    registerFixtureClasses(model)
    return model
}

func makeStore(_ model: NSManagedObjectModel, _ url: URL, readOnly: Bool, wal: Bool = false) throws -> (NSPersistentStoreCoordinator, NSPersistentStore, NSManagedObjectContext) {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    var options: [AnyHashable: Any] = [NSMigratePersistentStoresAutomaticallyOption: false,
                                     NSInferMappingModelAutomaticallyOption: false,
                                     NSReadOnlyPersistentStoreOption: readOnly]
    if !readOnly { options[NSSQLitePragmasOption] = ["journal_mode": wal ? "WAL" : "DELETE", "wal_autocheckpoint": "0"] }
    let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: options)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return (coordinator, store, context)
}

func fillRequired(_ object: NSManagedObject) throws {
    for (name, attribute) in object.entity.attributesByName where !attribute.isOptional && !attribute.isTransient {
        if object.value(forKey: name) != nil { continue }
        let value: Any
        switch attribute.attributeType {
        case .stringAttributeType: value = "fixture-\(object.entity.name!)-\(name)"
        case .dateAttributeType: value = Date(timeIntervalSince1970: 1_700_000_000)
        case .booleanAttributeType: value = false
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: value = 1
        case .doubleAttributeType, .floatAttributeType: value = 1.25
        default: throw NSError(domain: "SchemaQualification", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected required fixture attribute"])
        }
        object.setValue(value, forKey: name)
    }
}

func seed(_ model: NSManagedObjectModel, _ path: URL, wal: Bool) throws {
    let (coordinator, store, context) = try makeStore(model, path, readOnly: false, wal: wal)
    var objects: [String: NSManagedObject] = [:]
    for name in testedEntities {
        let object = NSEntityDescription.insertNewObject(forEntityName: name, into: context)
        try fillRequired(object); objects[name] = object
    }
    objects["Account"]!.setValue(true, forKey: "isActiveAccount")
    objects["Team"]!.setValue(objects["Account"]!, forKey: "account")
    objects["InstalledApp"]!.setValue(objects["Team"]!, forKey: "team")
    objects["InstalledExtension"]!.setValue(objects["InstalledApp"]!, forKey: "parentApp")
    try context.save()
    objects["Account"]!.setValue("latest-committed-fixture-name", forKey: "firstName")
    try context.save()
    if wal {
        FileHandle.standardOutput.write(Data("WAL_WRITER_COMMITTED\n".utf8))
        _exit(0) // Deliberately leave committed WAL, with no live writer afterwards.
    }
    try coordinator.remove(store)
}

func identifier(_ object: NSManagedObject) -> String {
    let key = object.entity.attributesByName["identifier"] != nil ? "identifier" : "bundleIdentifier"
    return object.entity.name! + ":" + String(describing: object.value(forKey: key)!)
}
func scalar(_ value: Any?) throws -> Any {
    guard let value else { return NSNull() }
    if let date = value as? Date { return ["date": date.timeIntervalSince1970] }
    if let number = value as? NSNumber { return number }
    if let string = value as? String { return string }
    throw NSError(domain: "SchemaQualification", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unsupported snapshot value"])
}
func snapshot(_ model: NSManagedObjectModel, _ path: URL, includeFingerprint: Bool = false) throws -> Data {
    let (coordinator, store, context) = try makeStore(model, path, readOnly: true)
    defer { try? coordinator.remove(store) }
    var rows: [[String: Any]] = []
    for name in testedEntities {
        let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name))
        try require(objects.count == 1, "Fixture entity count changed")
        for object in objects {
            var row: [String: Any] = ["entity": name, "id": identifier(object)]
            for (key, attr) in object.entity.attributesByName where !attr.isTransient {
                if key == "appBundleFingerprint" {
                    try require(object.value(forKey: key) == nil, "Added optional attribute not nil")
                    if !includeFingerprint { continue }
                }
                row[key] = try scalar(object.value(forKey: key))
            }
            for (key, relation) in object.entity.relationshipsByName {
                if relation.isToMany {
                    let values = (object.value(forKey: key) as? NSSet)?.allObjects as? [NSManagedObject] ?? []
                    row["relationship:" + key] = values.map(identifier).sorted()
                } else {
                    row["relationship:" + key] = (object.value(forKey: key) as? NSManagedObject).map(identifier) ?? "nil"
                }
            }
            rows.append(row)
        }
    }
    try require(rows.first(where: { ($0["entity"] as? String) == "Account" })?["firstName"] as? String == "latest-committed-fixture-name", "Latest committed WAL record lost")
    return try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
}


final class RelationshipPreservingMergePolicy: NSMergePolicy {
    init() { super.init(merge: .errorMergePolicyType) }
}
func debugLog(_ message: String) { /* Synthetic fixture does not emit underlying errors. */ }
extension FileManager {
    var cachesDirectory: URL { temporaryDirectory }
    var altstoreSharedDirectory: URL? { URL(fileURLWithPath: CommandLine.arguments[3]).deletingLastPathComponent() }
}

@main struct CoreDataRecoveryTests {
    static func main() throws {
        let args = CommandLine.arguments
        try require(args.count == 4, "Expected mode, bundle, root")
        let bundleURL = URL(fileURLWithPath: args[2])
        let models = bundleURL.appendingPathComponent("Contents/Resources/AltStore.momd")
        let root = URL(fileURLWithPath: args[3])
        let old = try loadModel(models, "17_6"), new = try loadModel(models, "17_7")
        if args[1] == "seed-wal" || args[1] == "seed-delete" {
            try seed(old, root, wal: args[1] == "seed-wal")
            return
        }
        guard let bundle = Bundle(url: bundleURL) else { throw DatabaseRecovery.Failure.storage }
        let shared = root.appendingPathComponent("shared/Database")
        let privateRoot = root.appendingPathComponent("private")
        let source = privateRoot.appendingPathComponent("AltStore.sqlite")
        let roots = DatabaseRecovery.Roots(sharedDatabase: shared, privateDatabase: privateRoot,
            sharedApps: root.appendingPathComponent("shared/Apps"), privateApps: root.appendingPathComponent("privateApps"))
        let container = PersistentContainer(name: "AltStore", bundle: bundle)
        let selection = try DatabaseRecovery().resolve(roots) { url, migrate in
            try container.validateRecoveryStore(at: url, migrateStagedCopy: migrate)
        }
        try require(selection.database.path.contains("RecoveredStore-v1/"), "Recovery generation not selected")
        // Only inspect source with SQLite-managed Core Data connections while its
        // SQLite reservation lives. No direct source file hashing or FileHandles.
        let before = try snapshot(old, source)
        let after = try snapshot(new, selection.database)
        try require(before == after, "Recovered graph lost data or relationships")
        try require(FileManager.default.fileExists(atPath: source.path), "Original source removed")
        print("EXACT_RECOVERY_ENGINE_AND_PERSISTENT_CONTAINER_COREDATA_PASS")
        withExtendedLifetime(selection) {}
    }
}
