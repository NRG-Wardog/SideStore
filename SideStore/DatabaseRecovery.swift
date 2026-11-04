// Database relocation is copy-on-write. Originals are never removed or replaced.
// The only publication point is an exclusive rename of a complete generation.
import Foundation
import CryptoKit
import SQLite3
import Darwin

@_silgen_name("sidestore_recovery_disable_close_checkpoint")
private func disableCloseCheckpoint(_ database: OpaquePointer) -> Int32

final class DatabaseRecovery {
    enum Failure: Error { case unsafeLayout, conflict, sourceBusy, sourceChanged, invalidReceipt, storage, sqlite }
    struct Selection {
        let database: URL
        let apps: URL?
        let identity: String?
        // Retain SQLite write reservations for as long as the selected store is used.
        let ownership: [SourceReservation]
    }
    struct Roots {
        let sharedDatabase: URL
        let privateDatabase: URL
        let sharedApps: URL
        let privateApps: URL
    }
    private struct Source: Codable, Equatable {
        let location: String
        let name: String
        let snapshot: String
    }
    private struct Receipt: Codable {
        let version: Int
        let sources: [Source]
        let apps: [String: [String: String]]
        let storeIdentity: String
    }
    private static let generationName = "RecoveredStore-v1"
    private static let storeName = "SideStore.sqlite"
    private static let receiptName = "recovery.json"
    private static let startupLockName = ".recovery-startup.lock"
    private static let names = ["AltStore.sqlite", "SideStore.sqlite"]
    private static let sidecars = ["-wal", "-shm", "-journal"]
    private let fm = FileManager.default

    static func hasPublishedGeneration(in directory: URL) -> Bool {
        var info = stat()
        let path = directory.appendingPathComponent(generationName).path
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    static func withResetLock(in directory: URL, operation: () -> Bool) -> Bool {
        do {
            let root = try DatabaseRecovery().directory(directory, create: true)
            let fd = open(root.appendingPathComponent(startupLockName).path,
                          O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
            defer { flock(fd, LOCK_UN) }
            return operation()
        } catch { return false }
    }

    // All source roots are app-owned. This entry point is also used verbatim by
    // the native synthetic-fixture harness, with fresh temporary roots only.
    func resolve(_ roots: Roots, validate: (URL, Bool) throws -> String) throws -> Selection {
        let shared = try directory(roots.sharedDatabase, create: true)
        let privateRoot = try directory(roots.privateDatabase, create: false)
        let sharedApps = try directory(roots.sharedApps, create: false)
        let privateApps = try directory(roots.privateApps, create: false)
        let generation = shared.appendingPathComponent(Self.generationName, isDirectory: true)
        let lockURL = shared.appendingPathComponent(Self.startupLockName)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.storage }
        defer { close(fd) }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw Failure.unsafeLayout }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.sourceBusy }
        defer { flock(fd, LOCK_UN) }

        var candidates: [(location: String, url: URL)] = []
        for (location, root) in [("shared", shared), ("private", privateRoot)] {
            if location == "private" && root == shared { continue }
            for name in Self.names {
                let url = root.appendingPathComponent(name)
                let present = try regularFile(url)
                for suffix in Self.sidecars {
                    let sidecar = URL(fileURLWithPath: url.path + suffix)
                    if try regularFile(sidecar) {
                        guard present else { throw Failure.unsafeLayout }
                        // A rollback journal can require recovery that writes the original.
                        // Keep it intact and require the previous version to close cleanly.
                        if suffix == "-journal", try sidecar.resourceValues(forKeys: [.fileSizeKey]).fileSize != 0 {
                            throw Failure.unsafeLayout
                        }
                    }
                }
                // Core Data external binary storage requires its own coordinated
                // snapshot protocol. Do not quietly drop opaque support directories.
                for name in ["." + url.lastPathComponent + "_SUPPORT", url.deletingPathExtension().lastPathComponent + "_SUPPORT", "." + url.deletingPathExtension().lastPathComponent + "_SUPPORT"] {
                    if exists(root.appendingPathComponent(name)) { throw Failure.unsafeLayout }
                }
                if present { candidates.append((location, url)) }
            }
        }
        let hasGeneration = exists(generation)
        var oldAppsPresent = false
        if privateApps != sharedApps, exists(privateApps) { oldAppsPresent = !(try inventory(privateApps)).isEmpty }
        // No relocation needed. Retain the pre-existing shared filename so its WAL
        // and normal schema migration stay with it. Never create an empty database
        // merely because an unresolved private store was found.
        if !hasGeneration, !oldAppsPresent,
           candidates.allSatisfy({ $0.location == "shared" }), candidates.count <= 1 {
            return Selection(database: candidates.first?.url ?? shared.appendingPathComponent(Self.storeName), apps: nil, identity: nil, ownership: [])
        }
        guard !candidates.isEmpty else { throw Failure.conflict }
        let reservations = try candidates.map { try SourceReservation($0.url) }
        let stage = shared.appendingPathComponent(".recovery-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Only this invocation's random, never-published staging directory is removed.
        defer { if exists(stage) { try? fm.removeItem(at: stage) } }
        var sources: [Source] = []
        for (index, candidate) in candidates.enumerated() {
            let snapshot = stage.appendingPathComponent("source-\(index).sqlite")
            try reservations[index].snapshot(to: snapshot)
            sources.append(Source(location: candidate.location, name: candidate.url.lastPathComponent,
                                  snapshot: try digest(snapshot)))
        }
        let appRoots = [("shared", sharedApps), ("private", privateApps)]
        var appInventories: [String: [String: String]] = [:]
        for (location, root) in appRoots where location != "private" || root != sharedApps {
            appInventories[location] = try inventory(root)
        }
        if hasGeneration {
            _ = try directory(generation, create: false)
            let receiptURL = generation.appendingPathComponent(Self.receiptName)
            guard try regularFile(receiptURL),
                  (try receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 16 * 1024 * 1024 else { throw Failure.invalidReceipt }
            let receipt: Receipt
            do { receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL)) }
            catch { throw Failure.invalidReceipt }
            guard receipt.version == 1, receipt.sources == sources,
                  receipt.apps == appInventories else { throw Failure.sourceChanged }
            let database = generation.appendingPathComponent(Self.storeName)
            guard try regularFile(database), try validate(database, false) == receipt.storeIdentity else { throw Failure.invalidReceipt }
            let apps = try directory(generation.appendingPathComponent("Apps"), create: false)
            guard exists(apps) else { throw Failure.invalidReceipt }
            return Selection(database: database, apps: apps, identity: receipt.storeIdentity, ownership: reservations)
        }
        // Do not pick the newest/largest store, prefer a filename, or merge rows.
        // Equivalent normalized SQLite snapshots are the only automatic conflict resolution.
        guard Set(sources.map(\.snapshot)).count == 1 else { throw Failure.conflict }
        let apps = stage.appendingPathComponent("Apps", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var merged: [String: String] = [:]
        for (location, root) in appRoots where location != "private" || root != sharedApps {
            for (path, signature) in appInventories[location] ?? [:] {
                if let prior = merged[path], prior != signature { throw Failure.conflict }
                merged[path] = signature
            }
            try copyTree(root, to: apps)
        }
        // Apply directory modes only after all roots are merged. A read-only
        // source directory must not prevent copying a missing sibling from the
        // other equivalent root. Descendants are finalized before their parents.
        for path in merged.keys.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            if let signature = merged[path], signature.hasPrefix("directory:"),
               let permissions = Int(signature.dropFirst("directory:".count)) {
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: apps.appendingPathComponent(path).path)
            }
        }
        guard try inventory(apps) == merged else { throw Failure.sourceChanged }
        let database = stage.appendingPathComponent(Self.storeName)
        try fm.moveItem(at: stage.appendingPathComponent("source-0.sqlite"), to: database)
        // Migrate/validate only the owned staging copy, never the retained source.
        let identity = try validate(database, true)
        for (index, candidate) in candidates.enumerated() {
            let check = stage.appendingPathComponent("check-\(index).sqlite")
            try reservations[index].snapshot(to: check)
            guard try digest(check) == sources[index].snapshot else { throw Failure.sourceChanged }
            _ = candidate // order is bound to receipt.sources
        }
        for (location, root) in appRoots where location != "private" || root != sharedApps {
            guard try inventory(root) == appInventories[location] else { throw Failure.sourceChanged }
        }
        // Remove only synthetic snapshot/check copies before publishing the generation.
        for item in try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) {
            if item.lastPathComponent.hasPrefix("source-") || item.lastPathComponent.hasPrefix("check-") {
                try fm.removeItem(at: item)
            }
        }
        let receipt = Receipt(version: 1, sources: sources, apps: appInventories, storeIdentity: identity)
        let receiptData = try JSONEncoder().encode(receipt)
        guard receiptData.count < 16 * 1024 * 1024 else { throw Failure.storage }
        try receiptData.write(to: stage.appendingPathComponent(Self.receiptName), options: .withoutOverwriting)
        try synchronizeTree(stage)
        // renameatx_np(RENAME_EXCL) is atomic and never replaces an existing directory.
        // The receipt, database (including any migration sidecars), and Apps travel together.
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, generation.path, UInt32(RENAME_EXCL)) == 0 else { throw Failure.storage }
        try synchronizeDirectory(shared)
        return Selection(database: generation.appendingPathComponent(Self.storeName),
                         apps: generation.appendingPathComponent("Apps"), identity: identity, ownership: reservations)
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }
    private func directory(_ url: URL, create: Bool) throws -> URL {
        if !exists(url) {
            if create { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            else { return url.resolvingSymlinksInPath().standardizedFileURL }
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unsafeLayout }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
    private func regularFile(_ url: URL) throws -> Bool {
        guard exists(url) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.unsafeLayout }
        return true
    }
    private func digest(_ url: URL) throws -> String {
        guard try regularFile(url) else { throw Failure.unsafeLayout }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func mode(_ url: URL) throws -> Int {
        guard let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else { throw Failure.unsafeLayout }
        return mode.intValue
    }
    private func inventory(_ root: URL) throws -> [String: String] {
        guard exists(root) else { return [:] }
        _ = try directory(root, create: false)
        var result: [String: String] = [:]
        func visit(_ parent: URL, prefix: String) throws {
            for item in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw Failure.unsafeLayout }
                let path = prefix + item.lastPathComponent
                if values.isDirectory == true {
                    result[path] = "directory:" + String(try mode(item))
                    try visit(item, prefix: path + "/")
                } else {
                    result[path] = "file:" + String(try mode(item)) + ":" + (try digest(item))
                }
            }
        }
        try visit(root, prefix: "")
        return result
    }
    private func copyTree(_ source: URL, to target: URL) throws {
        guard exists(source) else { return }
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure.unsafeLayout }
            if values.isDirectory == true {
                if !exists(destination) { try fm.createDirectory(at: destination, withIntermediateDirectories: false) }
                _ = try directory(destination, create: false)
                try copyTree(item, to: destination)
            } else if exists(destination) {
                guard try digest(item) == digest(destination), try mode(item) == mode(destination) else { throw Failure.conflict }
            } else {
                guard try regularFile(item) else { throw Failure.unsafeLayout }
                try fm.copyItem(at: item, to: destination)
            }
        }
    }
    private func synchronizeDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.storage }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.storage }
    }
    private func synchronizeTree(_ root: URL) throws {
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try synchronizeTree(item) }
            else { try synchronizeDirectory(item) }
        }
        try synchronizeDirectory(root)
    }

    final class SourceReservation {
        private var writer: OpaquePointer?
        private let url: URL
        init(_ url: URL) throws {
            self.url = url
            let result = sqlite3_open_v2(url.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW, nil)
            guard result == SQLITE_OK, let writer else {
                if let writer { sqlite3_close(writer) }
                self.writer = nil
                throw Failure.sqlite
            }
            sqlite3_busy_timeout(writer, 0)
            // Do not checkpoint a retained original merely because this guard closes.
            guard disableCloseCheckpoint(writer) == SQLITE_OK,
                  sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(writer); self.writer = nil
                throw Failure.sourceBusy
            }
        }
        deinit {
            if let writer {
                sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
                sqlite3_close(writer)
            }
        }
        func snapshot(to destination: URL) throws {
            var source: OpaquePointer?
            guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
                  let source else {
                if let source { sqlite3_close(source) }
                throw Failure.sqlite
            }
            defer { sqlite3_close(source) }
            let descriptor = open(destination.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw Failure.storage }
            close(descriptor)
            var target: OpaquePointer?
            guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
                  let target else {
                if let target { sqlite3_close(target) }
                throw Failure.sqlite
            }
            defer { sqlite3_close(target) }
            guard let backup = sqlite3_backup_init(target, "main", source, "main") else { throw Failure.sqlite }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK,
                  sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
            var check: OpaquePointer?
            guard sqlite3_prepare_v2(target, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK, let check else { throw Failure.sqlite }
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, let text = sqlite3_column_text(check, 0),
                  String(cString: text) == "ok", sqlite3_step(check) == SQLITE_DONE else { throw Failure.sqlite }
        }
    }
}
