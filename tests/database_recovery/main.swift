// Native qualification of the exact production recovery engine, with synthetic data.
import Foundation
import SQLite3
import Darwin

struct TestFailure: Error, CustomStringConvertible { let description: String }
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(description: message) }
}
func database<T>(_ path: URL, readOnly: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
    var pointer: OpaquePointer?
    let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_PRIVATECACHE
    let result = sqlite3_open_v2(path.path, &pointer, flags, nil)
    guard result == SQLITE_OK, let db = pointer else {
        if let pointer { sqlite3_close(pointer) }
        throw TestFailure(description: "open failed: \(result)")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 0)
    return try body(db)
}
func sql(_ db: OpaquePointer, _ statement: String) throws {
    let result = sqlite3_exec(db, statement, nil, nil, nil)
    try require(result == SQLITE_OK, "SQL failed \(result): \(statement)")
}
func row(_ path: URL) throws -> String {
    try database(path, readOnly: true) { db in
        var statement: OpaquePointer?
        try require(sqlite3_prepare_v2(db, "SELECT value FROM fixture WHERE id=1", -1, &statement, nil) == SQLITE_OK, "prepare row")
        guard let statement else { throw TestFailure(description: "missing statement") }
        defer { sqlite3_finalize(statement) }
        try require(sqlite3_step(statement) == SQLITE_ROW, "missing fixture row")
        return String(cString: sqlite3_column_text(statement, 0))
    }
}
let fm = FileManager.default
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
func child(_ mode: String, _ path: URL) throws {
    let task = Process()
    task.executableURL = executable
    task.arguments = [mode, path.path]
    try task.run()
    task.waitUntilExit()
    try require(task.terminationReason == .exit && task.terminationStatus == 0,
                "child \(mode) failed: \(task.terminationStatus)")
}
func seed(_ path: URL, value: String = "original") throws {
    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try database(path) { db in
        try sql(db, "PRAGMA journal_mode=DELETE; CREATE TABLE fixture(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO fixture VALUES(1,'\(value)');")
    }
}
func validate(_ path: URL, _ migrate: Bool) throws -> String {
    _ = try row(path)
    return "synthetic-fixture-v1"
}
func rejected(_ body: () throws -> Void) throws {
    do { try body() }
    catch let failure as TestFailure { throw failure }
    catch { return }
    throw TestFailure(description: "Expected recovery rejection")
}
func typedRejection(_ expected: DatabaseRecovery.Failure, _ body: () throws -> Void) throws {
    do { try body() }
    catch let actual as DatabaseRecovery.Failure {
        try require(String(describing: actual) == String(describing: expected), "Unexpected rejection: \(actual), expected \(expected)")
        return
    }
    throw TestFailure(description: "Expected typed recovery rejection: \(expected)")
}
struct Fixture {
    let root: URL
    var roots: DatabaseRecovery.Roots {
        .init(sharedDatabase: root.appendingPathComponent("shared/Database"),
              privateDatabase: root.appendingPathComponent("private/Database"),
              sharedApps: root.appendingPathComponent("shared/Apps"),
              privateApps: root.appendingPathComponent("private/Apps"))
    }
    var source: URL { roots.privateDatabase.appendingPathComponent("AltStore.sqlite") }
    var generation: URL { roots.sharedDatabase.appendingPathComponent("RecoveredStore-v1") }
    init(_ root: URL) throws {
        self.root = root
        for directory in [roots.sharedDatabase, roots.privateDatabase, roots.sharedApps, roots.privateApps] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
    func app(_ shared: Bool, text: String) throws {
        let directory = (shared ? roots.sharedApps : roots.privateApps).appendingPathComponent("test.app")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent("binary"))
    }
}

func main() throws {
    if CommandLine.arguments.count == 3 {
        let mode = CommandLine.arguments[1], path = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "seed-wal" {
            try database(path) { db in
                try sql(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE fixture(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO fixture VALUES(1,'latest-committed-wal');")
                _exit(0) // Real committed WAL remains without connection-close checkpoint.
            }
        } else if mode == "seed-hot-journal" {
            try database(path) { db in
                try sql(db, "PRAGMA journal_mode=DELETE; BEGIN IMMEDIATE; UPDATE fixture SET value='uncommitted';")
                _exit(0)
            }
        } else if mode == "exit-before-publication" {
            let fixture = try Fixture(path)
            _ = try DatabaseRecovery().resolve(fixture.roots) { database, migrate in
                _ = try validate(database, migrate)
                _exit(0) // No defer cleanup: owned staging must remain unselected.
            }
            throw TestFailure(description: "Interruption point was not reached")
        } else if mode == "exit-after-publication" {
            let fixture = try Fixture(path)
            let selection = try DatabaseRecovery().resolve(fixture.roots, validate: validate)
            try require(selection.database.resolvingSymlinksInPath().standardizedFileURL == fixture.generation.appendingPathComponent("SideStore.sqlite").resolvingSymlinksInPath().standardizedFileURL, "Committed generation not selected")
            try require(try row(selection.database) == "original", "Published or resumed generation changed")
            withExtendedLifetime(selection) {
                _exit(0) // Source reservations are released by process death, not deinit.
            }
        } else if mode == "resolve-blocked" {
            let fixture = try Fixture(path)
            try typedRejection(.sourceBusy) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
        } else if mode == "writer-blocked" || mode == "writer-allowed" {
            try database(path) { db in
                let result = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
                if mode == "writer-blocked" {
                    try require(result == SQLITE_BUSY || result == SQLITE_LOCKED, "Legacy writer was not excluded: \(result)")
                } else {
                    try require(result == SQLITE_OK, "Writer remained blocked after owner exit")
                    try sql(db, "UPDATE fixture SET value='legacy-divergence'; COMMIT;")
                }
            }
        } else { throw TestFailure(description: "Unknown child mode") }
        return
    }
    try require(CommandLine.arguments.count == 2, "Usage: fixture OUTPUT_DIRECTORY")
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    var cases: [String] = []
    func run(_ name: String, _ body: (Fixture) throws -> Void) throws {
        FileHandle.standardOutput.write(Data("BEGIN \(name)\n".utf8))
        let fixture = try Fixture(output.appendingPathComponent(name))
        do { try body(fixture) }
        catch {
            FileHandle.standardError.write(Data("FAILED_CASE \(name)\n".utf8))
            throw error
        }
        cases.append(name)
        print("PASS \(name)")
    }
    try run("wal-and-process-lease") { fixture in
        try child("seed-wal", fixture.source)
        let wal = URL(fileURLWithPath: fixture.source.path + "-wal")
        try require((try wal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 32, "No real committed WAL")
        let reservation = try DatabaseRecovery.SourceReservation(fixture.source)
        try child("writer-blocked", fixture.source)
        let backup = fixture.root.appendingPathComponent("direct-backup.sqlite")
        try reservation.snapshot(to: backup)
        try require(try row(backup) == "latest-committed-wal", "Backup lost committed WAL row")
        try child("writer-blocked", fixture.source)
        withExtendedLifetime(reservation) {}
    }
    try run("wal-relocation-and-resume") { fixture in
        try child("seed-wal", fixture.source)
        do {
            let selection = try DatabaseRecovery().resolve(fixture.roots) { path, migrate in
                try child("writer-blocked", fixture.source)
                return try validate(path, migrate)
            }
            try require(try row(selection.database) == "latest-committed-wal", "Relocation lost committed WAL row")
            try child("resolve-blocked", fixture.root)
            try child("writer-blocked", fixture.source)
            try database(selection.database) { try sql($0, "UPDATE fixture SET value='destination-edit';") }
            try Data("mutable".utf8).write(to: selection.apps!.appendingPathComponent("new-file"))
            withExtendedLifetime(selection) {}
        }
        do {
            let resumed = try DatabaseRecovery().resolve(fixture.roots, validate: validate)
            try require(try row(resumed.database) == "destination-edit", "Resume rejected/reverted legitimate destination edits")
            try require(fm.fileExists(atPath: resumed.apps!.appendingPathComponent("new-file").path), "Destination Apps edit lost")
            withExtendedLifetime(resumed) {}
        }
        try child("writer-allowed", fixture.source)
        try typedRejection(.sourceChanged) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
        try require(try row(fixture.generation.appendingPathComponent("SideStore.sqlite")) == "destination-edit", "Divergence overwrote destination")
    }
    try run("identical-databases") { fixture in
        try seed(fixture.source)
        try fm.copyItem(at: fixture.source, to: fixture.roots.sharedDatabase.appendingPathComponent("SideStore.sqlite"))
        let selected = try DatabaseRecovery().resolve(fixture.roots, validate: validate)
        try require(try row(selected.database) == "original", "Equivalent originals failed")
        withExtendedLifetime(selected) {}
    }
    try run("different-databases") { fixture in
        try seed(fixture.source)
        let shared = fixture.roots.sharedDatabase.appendingPathComponent("SideStore.sqlite")
        try seed(shared, value: "different")
        try typedRejection(.conflict) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
        try require(try row(shared) == "different", "Conflicting destination changed")
        try require(try row(fixture.source) == "original", "Conflicting source changed")
    }
    try run("identical-apps") { fixture in
        try seed(fixture.source); try fixture.app(false, text: "same"); try fixture.app(true, text: "same")
        let selection = try DatabaseRecovery().resolve(fixture.roots, validate: validate)
        try require(try Data(contentsOf: selection.apps!.appendingPathComponent("test.app/binary")) == Data("same".utf8), "Apps copy mismatch")
        withExtendedLifetime(selection) {}
    }
    try run("different-apps") { fixture in
        try seed(fixture.source); try fixture.app(false, text: "private"); try fixture.app(true, text: "shared")
        try typedRejection(.conflict) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
        try require(!fm.fileExists(atPath: fixture.generation.path), "Conflicting Apps published")
    }
    try run("apps-changed-before-publication") { fixture in
        try seed(fixture.source); try fixture.app(false, text: "before")
        try typedRejection(.sourceChanged) {
            _ = try DatabaseRecovery().resolve(fixture.roots) { path, migrate in
                try fixture.app(false, text: "after")
                return try validate(path, migrate)
            }
        }
        try require(!fm.fileExists(atPath: fixture.generation.path), "Changed Apps published")
    }
    try run("malformed-receipt") { fixture in
        try seed(fixture.source)
        do { let selection = try DatabaseRecovery().resolve(fixture.roots, validate: validate); withExtendedLifetime(selection) {} }
        try Data("not-json".utf8).write(to: fixture.generation.appendingPathComponent("recovery.json"))
        try rejected { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
        try require(try row(fixture.source) == "original", "Malformed receipt changed source")
    }
    try run("source-ancestor-symlink") { fixture in
        try seed(fixture.source)
        let linkedParent = fixture.root.appendingPathComponent("linked-private")
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: fixture.roots.privateDatabase)
        do {
            _ = try DatabaseRecovery.SourceReservation(linkedParent.appendingPathComponent("AltStore.sqlite"))
            throw TestFailure(description: "NOFOLLOW accepted a linked ancestor")
        } catch let error as DatabaseRecovery.SQLiteFailure {
            try require(error.phase == .sourceOpen && (error.code & 0xff) == SQLITE_CANTOPEN,
                        "Wrong bounded ancestor-symlink rejection")
        }
        try require(try row(fixture.source) == "original", "Rejected linked path changed source")
    }
    try run("source-symlink") { fixture in
        let actual = fixture.root.appendingPathComponent("actual.sqlite")
        try seed(actual)
        try fm.createSymbolicLink(at: fixture.source, withDestinationURL: actual)
        try typedRejection(.unsafeLayout) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
    }
    try run("apps-symlink") { fixture in
        try seed(fixture.source)
        try fm.createSymbolicLink(at: fixture.roots.privateApps.appendingPathComponent("escape"), withDestinationURL: fixture.root)
        try typedRejection(.unsafeLayout) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
    }
    try run("orphan-sidecar") { fixture in
        try Data("orphan".utf8).write(to: URL(fileURLWithPath: fixture.source.path + "-wal"))
        try typedRejection(.unsafeLayout) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
    }
    try run("real-rollback-journal") { fixture in
        try seed(fixture.source)
        try child("seed-hot-journal", fixture.source)
        let journal = URL(fileURLWithPath: fixture.source.path + "-journal")
        let before = try Data(contentsOf: journal)
        try require(!before.isEmpty, "No actual rollback journal")
        try typedRejection(.unsafeLayout) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
        try require(try Data(contentsOf: journal) == before, "Rejected journal changed")
    }
    try run("validation-failure-before-promotion") { fixture in
        try seed(fixture.source)
        try typedRejection(.storage) {
            _ = try DatabaseRecovery().resolve(fixture.roots) { _, _ in throw DatabaseRecovery.Failure.storage }
        }
        try require(!fm.fileExists(atPath: fixture.generation.path), "Failed validation published")
        try require(try row(fixture.source) == "original", "Failed validation changed original")
        let selection = try DatabaseRecovery().resolve(fixture.roots, validate: validate)
        withExtendedLifetime(selection) {}
    }
    try run("racer-created-generation") { fixture in
        try seed(fixture.source)
        try typedRejection(.storage) {
            _ = try DatabaseRecovery().resolve(fixture.roots) { path, migrate in
                try fm.createDirectory(at: fixture.generation, withIntermediateDirectories: false)
                try Data("racer".utf8).write(to: fixture.generation.appendingPathComponent("sentinel"))
                return try validate(path, migrate)
            }
        }
        try require(try Data(contentsOf: fixture.generation.appendingPathComponent("sentinel")) == Data("racer".utf8), "Exclusive publication overwrote racer")
        try require(!fm.fileExists(atPath: fixture.generation.appendingPathComponent("recovery.json").path), "Racer gained receipt")
    }
    try run("process-exit-before-publication") { fixture in
        try seed(fixture.source)
        try fixture.app(false, text: "preserved-app")
        try child("exit-before-publication", fixture.root)
        try require(!fm.fileExists(atPath: fixture.generation.path), "Interrupted staging was published")
        let abandoned = try fm.contentsOfDirectory(at: fixture.roots.sharedDatabase,
            includingPropertiesForKeys: [.isDirectoryKey]).filter {
                $0.lastPathComponent.hasPrefix(".recovery-") &&
                    ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }
        try require(abandoned.count == 1, "Interruption did not retain exactly one staging directory")
        let selection = try DatabaseRecovery().resolve(fixture.roots, validate: validate)
        try require(selection.database.resolvingSymlinksInPath().standardizedFileURL == fixture.generation.appendingPathComponent("SideStore.sqlite").resolvingSymlinksInPath().standardizedFileURL, "Retry selected abandoned staging")
        try require(try row(selection.database) == "original", "Retry lost original data")
        try require(fm.fileExists(atPath: abandoned[0].path), "Retry deleted another invocation's staging")
        try require(try Data(contentsOf: selection.apps!.appendingPathComponent("test.app/binary")) == Data("preserved-app".utf8), "Retry lost Apps")
        withExtendedLifetime(selection) {}
    }
    try run("process-exit-after-publication-and-divergence") { fixture in
        try seed(fixture.source)
        try child("exit-after-publication", fixture.root)
        let receipt = fixture.generation.appendingPathComponent("recovery.json")
        let committedReceipt = try Data(contentsOf: receipt)
        // A second process must validate/reuse the completed generation after the
        // first owner died. Its own abrupt exit again releases the source lease.
        try child("exit-after-publication", fixture.root)
        try require(try Data(contentsOf: receipt) == committedReceipt, "Resume replaced immutable receipt")
        try child("writer-allowed", fixture.source)
        try require(try row(fixture.source) == "legacy-divergence", "Post-death legacy commit missing")
        try typedRejection(.sourceChanged) { _ = try DatabaseRecovery().resolve(fixture.roots, validate: validate) }
        try require(try row(fixture.generation.appendingPathComponent("SideStore.sqlite")) == "original", "Divergence replaced committed destination")
        try require(try Data(contentsOf: receipt) == committedReceipt, "Divergence changed receipt")
    }
    let report: [String: Any] = ["status": "PASS_NATIVE_EXACT_ENGINE_SYNTHETIC_SQLITE", "cases": cases,
        "production_coredata_validation": false, "physical_device_execution": false,
        "limitations": ["Synthetic validator, not Core Data migration.", "No exclusion of legacy filesystem-only Apps writers after final inventory.", "No power-loss durability proof or iOS data-protection qualification."]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
}
do { try main() }
catch { fputs("QUALIFICATION_FAILED: \(error)\n", stderr); exit(1) }
