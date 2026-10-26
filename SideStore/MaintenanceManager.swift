//
//  MaintenanceManager.swift
//  SideStore
//
//  Preservation-mode integration for the NRG validation branch.
//  This is not an implementation of upstream destructive maintenance passes.
//

import Foundation
import CoreData
import CryptoKit
import SideSign
import MinimuxerCommon

public final class MaintenanceManager: @unchecked Sendable {
    public static let shared = MaintenanceManager()

    // Keep the legacy counter untouched. In particular, missing/corrupt counters
    // must never replay old account, anisette, header, or pairing reset passes.
    public static let maintenanceCounterFileName = ".maintenance_counter"
    private static let preservationLedgerFileName = ".maintenance_preservation_v1.json"
    private let lock = NSLock()
    private var maintenanceTask: Task<Void, Never>?

    private init() {}

    /// Called by DatabaseManager.performStart(), before any store inspection/load.
    /// Keeping the existing SQLite URL avoids copying a live database/WAL pair.
    public func preparePersistentStoreURLs(in container: PersistentContainer) throws {
        #if !os(tvOS)
        guard FileManager.default.altstoreSharedDirectory != nil else {
            throw V3DatabaseStartupGuardFailure(cause: .databaseAppGroupUnavailable, underlying: DatabaseError.missingAppGroup(reason: "The shared container is unavailable. Existing data has not been moved or reset."))
        }
        #endif
        guard container.persistentStoreCoordinator.persistentStores.isEmpty,
              container.persistentStoreDescriptions.count == 1,
              let description = container.persistentStoreDescriptions.first,
              description.type == NSSQLiteStoreType else {
            throw V3DatabaseStartupGuardFailure(cause: .databaseStartupFailed, underlying: DatabaseError.migrationFailed(reason: "Cannot safely choose the database before loading its store. Existing data has not been moved or reset."))
        }
        let directory = PersistentContainer.defaultDirectoryURL()
        let fm = FileManager.default
        // Upstream removed the old private-container relocation. Never silently
        // create a shared store while that earlier database/cache is still pending.
        let privateDirectory = NSPersistentContainer.defaultDirectoryURL()
        if privateDirectory.resolvingSymlinksInPath().standardizedFileURL != directory.resolvingSymlinksInPath().standardizedFileURL {
            for name in [AppConstants.Database.legacyFileName, AppConstants.Database.fileName] {
                for suffix in ["", "-wal", "-shm"] {
                    if fm.fileExists(atPath: privateDirectory.appendingPathComponent(name + suffix).path) {
                        throw V3DatabaseStartupGuardFailure(cause: .databaseLayoutBlocked, underlying: DatabaseError.migrationFailed(reason: "A database remains in the previous private container. This validation build will not relocate or overwrite it. Keep the existing data and resolve the App Group migration before continuing."))
                    }
                }
            }
        }
        let oldApps = fm.applicationSupportDirectory.appendingPathComponent("Apps")
        let sharedApps = directory.deletingLastPathComponent().appendingPathComponent("Apps")
        if UserDefaults.standard.bool(forKey: "requiresAppGroupMigration"),
           oldApps.resolvingSymlinksInPath().standardizedFileURL != sharedApps.resolvingSymlinksInPath().standardizedFileURL,
           fm.fileExists(atPath: oldApps.path) {
            guard try fm.contentsOfDirectory(at: oldApps, includingPropertiesForKeys: nil).isEmpty else {
                throw V3DatabaseStartupGuardFailure(cause: .databaseLayoutBlocked, underlying: DatabaseError.migrationFailed(reason: "App data remains in the previous private container and migration is pending. Startup stopped without moving or replacing it. Keep the existing data and resolve the App Group migration before continuing."))
            }
        }
        let legacy = directory.appendingPathComponent(AppConstants.Database.legacyFileName)
        let current = directory.appendingPathComponent(AppConstants.Database.fileName)
        let legacyExists = fm.fileExists(atPath: legacy.path)
        let currentExists = fm.fileExists(atPath: current.path)
        let legacySidecars = ["-wal", "-shm"].contains { fm.fileExists(atPath: legacy.path + $0) }
        let currentSidecars = ["-wal", "-shm"].contains { fm.fileExists(atPath: current.path + $0) }
        guard !(legacyExists && currentExists),
              !(!legacyExists && legacySidecars),
              !(!currentExists && currentSidecars) else {
            throw V3DatabaseStartupGuardFailure(cause: .databaseLayoutConflict, underlying: DatabaseError.migrationFailed(reason: "Multiple database layouts or orphaned SQLite sidecars were found. Startup stopped without changing them. Keep both layouts and contact support; do not reset the database."))
        }
        let selected = legacyExists ? legacy : current
        if legacyExists || currentExists {
            let values = try selected.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw V3DatabaseStartupGuardFailure(cause: .databaseLayoutConflict, underlying: DatabaseError.migrationFailed(reason: "The existing database is not a regular store file. Startup stopped without changing it."))
            }
        }
        description.url = selected
    }

    public func performMaintenanceIfNeeded() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let task = maintenanceTask { return task }
            let task = Task { await self.performPreservingMaintenance() }
            maintenanceTask = task
            return task
        }
        await task.value
    }
}

private extension MaintenanceManager {
    struct Outcomes: Codable, Sendable {
        var copied = 0
        var identical = 0
        var conflict = 0
        var pending = 0
        var absent = 0
        var retainedExistingReference = 0

        mutating func record(_ outcome: CopyOutcome) {
            switch outcome {
            case .copied: copied += 1
            case .identical: identical += 1
            case .conflict: conflict += 1
            }
        }
    }

    struct PreservationLedger: Encodable {
        let policy = "NRG-preservation-v1"
        // Excluded by policy, NOT completed, and NOT written to the old counter.
        let excludedLegacyPasses = [1, 2, 3, 6]
        let legacyCounterUnchanged = true
        let databaseLayout: String
        let appBundles: Outcomes
        let signingCertificates: Outcomes
        let pairingFiles: Outcomes
    }

    enum CopyOutcome { case copied, identical, conflict }
    enum PreservationError: Error { case unsafePath, unsupportedFile, verificationFailed }

    func performPreservingMaintenance() async {
        let bundles = await migrateLegacyCachedAppBundles()
        let certificates = await migrateLegacyCachedSigningCertificates()
        let pairing = migratePairingFiles()
        let storeName = DatabaseManager.shared.persistentContainer.persistentStoreDescriptions.first?.url?.lastPathComponent
        let layout = storeName == AppConstants.Database.legacyFileName ? "legacy-retained" : "current"
        let ledger = PreservationLedger(databaseLayout: layout, appBundles: bundles,
                                        signingCertificates: certificates, pairingFiles: pairing)
        // This is an audit snapshot, never a gate that suppresses future retries.
        // No paths, identifiers, content, hashes, or underlying errors are logged.
        if let shared = FileManager.default.altstoreSharedDirectory {
            do {
                let data = try JSONEncoder().encode(ledger)
                try data.write(to: shared.appendingPathComponent(Self.preservationLedgerFileName), options: .atomic)
            } catch {
                debugLog("[MaintenanceManager] Preservation audit could not be saved; originals remain available and migration will be rechecked next launch.")
            }
        }
        let pending = bundles.pending + certificates.pending + pairing.pending
        let conflicts = bundles.conflict + certificates.conflict + pairing.conflict
        debugLog("[MaintenanceManager] Preservation checks finished: pending=\(pending), conflicts=\(conflicts). Originals retained; reset passes excluded; legacy counter unchanged.")
    }

    func migrateLegacyCachedAppBundles() async -> Outcomes {
        // A dedicated context avoids rolling back or saving unrelated UI edits.
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return await context.perform {
            // A concurrent install may assign a newer payload after our fetch.
            // Fail that save and retry; never inherit an object-trump merge here.
            context.mergePolicy = NSErrorMergePolicy
            var outcomes = Outcomes()
            do {
                let installedApps = try context.fetch(InstalledApp.fetchRequest())
                var appsByBundleID: [String: [InstalledApp]] = [:]
                for app in installedApps {
                    for identifier in Set([app.bundleIdentifier, app.resignedBundleIdentifier]) {
                        appsByBundleID[identifier, default: []].append(app)
                    }
                }
                let appsDir = InstalledApp.appsDirectoryURL
                let directories = try FileManager.default.contentsOfDirectory(at: appsDir,
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                // Resolve every legacy candidate before choosing a payload. Both
                // original and resigned IDs may refer to the same InstalledApp.
                var sourcesByAppID: [NSManagedObjectID: [URL]] = [:]
                for directory in directories where directory.lastPathComponent != "Payloads" {
                    let source = directory.appendingPathComponent("App.app")
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    // Keep unknown/duplicate database records untouched rather than guessing.
                    guard let matches = appsByBundleID[directory.lastPathComponent], matches.count == 1,
                          let app = matches.first else {
                        outcomes.pending += 1
                        continue
                    }
                    sourcesByAppID[app.objectID, default: []].append(source)
                }
                for app in installedApps {
                    guard let sources = sourcesByAppID[app.objectID]?.sorted(by: { $0.path < $1.path }),
                          let source = sources.first else { continue }
                    // A retained old source must never revert a newer installed
                    // payload on a later launch. Only populate an unset reference.
                    guard app.appBundleFingerprint == nil else {
                        outcomes.retainedExistingReference += 1
                        continue
                    }
                    do {
                        // Snapshot all candidates. Never guess which original-ID
                        // or resigned-ID folder is newer when their bytes differ.
                        var snapshots: [(source: URL, digest: Data, signature: String)] = []
                        for candidate in sources {
                            try self.requireContained(candidate, within: appsDir)
                            let digest = try self.exactDigest(of: candidate)
                            guard let signature = AppBundleFingerprint.compute(for: candidate),
                                  try self.exactDigest(of: candidate) == digest else {
                                throw PreservationError.verificationFailed
                            }
                            snapshots.append((candidate, digest, signature))
                        }
                        guard let snapshot = snapshots.first,
                              snapshots.allSatisfy({ $0.digest == snapshot.digest && $0.signature == snapshot.signature }) else {
                            outcomes.conflict += 1
                            continue
                        }
                        let signature = snapshot.signature
                        let destination = InstalledApp.payloadURL(forSignature: signature)
                        let outcome = try self.copyPreservingOriginal(source, to: destination, within: appsDir,
                            expectedDigest: snapshot.digest, expectedFingerprint: signature)
                        switch outcome {
                        case .copied, .identical:
                            // Recheck every original and the actual published key
                            // before assigning a DB reference. A changed candidate
                            // stays retryable; any verified copy is merely retained.
                            guard try snapshots.allSatisfy({ try self.exactDigest(of: $0.source) == $0.digest }),
                                  AppBundleFingerprint.compute(for: destination) == signature else {
                                throw PreservationError.verificationFailed
                            }
                            app.appBundleFingerprint = signature
                        case .conflict:
                            break
                        }
                        outcomes.record(outcome)
                    } catch {
                        outcomes.pending += 1
                    }
                }
                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
                // Verified payload copies may exist, but no DB assignment is claimed.
                outcomes.pending += outcomes.copied + outcomes.identical + 1
                outcomes.copied = 0
                outcomes.identical = 0
            }
            return outcomes
        }
    }

    func migrateLegacyCachedSigningCertificates() async -> Outcomes {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return await context.perform {
            var outcomes = Outcomes()
            do {
                let installedApps = try context.fetch(InstalledApp.fetchRequest())
                let appsDir = InstalledApp.appsDirectoryURL
                for app in installedApps where app.bundleIdentifier != app.resignedBundleIdentifier {
                    let source = appsDir.appendingPathComponent(app.bundleIdentifier).appendingPathComponent("signing_certificate.der")
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    do {
                        outcomes.record(try self.copyPreservingOriginal(source, to: app.signingCertificateURL, within: appsDir))
                    } catch {
                        outcomes.pending += 1
                    }
                }
            } catch {
                outcomes.pending += 1
            }
            return outcomes
        }
    }

    func migratePairingFiles() -> Outcomes {
        var outcomes = Outcomes()
        let fm = FileManager.default
        let documents = fm.documentsDirectory
        let source = documents.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName)
        guard fm.fileExists(atPath: source.path) else { outcomes.absent += 1; return outcomes }
        do {
            try requireContained(source, within: documents)
            let validatedDigest = try exactDigest(of: source)
            let bytes = try Data(contentsOf: source)
            guard try exactDigest(of: source) == validatedDigest else {
                throw PreservationError.verificationFailed
            }
            guard let content = String(data: bytes, encoding: .utf8), !content.isEmpty else {
                outcomes.pending += 1
                return outcomes
            }
            let destinations: [(PairingProtocol, String)] = [
                (.rppairing, AppConstants.Pairing.remotePairingFileName),
                (.lockdown, AppConstants.Pairing.lockdownPairingFileName)
            ]
            var recognized = false
            for (mode, name) in destinations {
                guard let parsed = try? PairingFileManager.shared.parse(content: content, preferred: mode), parsed.mode == mode else { continue }
                recognized = true
                do {
                    let destination = documents.appendingPathComponent(name)
                    outcomes.record(try copyPreservingOriginal(source, to: destination, within: documents, expectedDigest: validatedDigest))
                } catch {
                    outcomes.pending += 1
                }
            }
            if !recognized { outcomes.pending += 1 }
        } catch {
            outcomes.pending += 1
        }
        // Original bytes, selected protocol, and reset preference remain untouched,
        // including parse errors, target conflicts, and partial copy failures.
        return outcomes
    }

    /// Copy to an owned staging path, verify actual bytes, then promote without
    /// replacing any existing destination. Sources are retained even on success.
    /// Needs proper iOS filesystem/CoreData fault testing before release.
    func requireContained(_ path: URL, within root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard path.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath) else {
            throw PreservationError.unsafePath
        }
    }

    func copyPreservingOriginal(_ source: URL, to destination: URL, within root: URL,
                                expectedDigest: Data? = nil, expectedFingerprint: String? = nil) throws -> CopyOutcome {
        let fm = FileManager.default
        try requireContained(source, within: root)
        try requireContained(destination, within: root)
        let before = try exactDigest(of: source)
        if let expectedDigest, before != expectedDigest { throw PreservationError.verificationFailed }
        if let expectedFingerprint, AppBundleFingerprint.compute(for: source) != expectedFingerprint {
            throw PreservationError.verificationFailed
        }
        if fm.fileExists(atPath: destination.path) {
            guard try exactDigest(of: destination) == before else { return .conflict }
            if let expectedFingerprint, AppBundleFingerprint.compute(for: destination) != expectedFingerprint {
                throw PreservationError.verificationFailed
            }
            return .identical
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".preservation-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) } // Only this invocation's scratch copy.
        try fm.copyItem(at: source, to: staging)
        guard try exactDigest(of: staging) == before, try exactDigest(of: source) == before else {
            throw PreservationError.verificationFailed
        }
        // The key must describe the copied snapshot BEFORE it is published, not
        // just the source observed earlier when the destination was selected.
        if let expectedFingerprint {
            guard AppBundleFingerprint.compute(for: staging) == expectedFingerprint,
                  AppBundleFingerprint.compute(for: source) == expectedFingerprint else {
                throw PreservationError.verificationFailed
            }
        }
        // moveItem fails rather than replacing an independently created target.
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if fm.fileExists(atPath: destination.path) {
                guard try exactDigest(of: destination) == before else { return .conflict }
                if let expectedFingerprint, AppBundleFingerprint.compute(for: destination) != expectedFingerprint {
                    throw PreservationError.verificationFailed
                }
                return .identical
            }
            throw error
        }
        guard try exactDigest(of: destination) == before else {
            throw PreservationError.verificationFailed
        }
        if let expectedFingerprint, AppBundleFingerprint.compute(for: destination) != expectedFingerprint {
            throw PreservationError.verificationFailed
        }
        return .copied
    }

    /// Content-and-structure digest, deliberately not AppBundleFingerprint.
    /// Unsupported/symlink trees stay untouched for explicit review.
    func exactDigest(of url: URL) throws -> Data {
        let fm = FileManager.default
        let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isSymbolicLink != true else { throw PreservationError.unsupportedFile }
        var hasher = SHA256()
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
        hasher.update(data: Data("mode:\(permissions)\n".utf8))
        if properties.isDirectory == true {
            hasher.update(data: Data("directory\n".utf8))
            let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let name = Data(child.lastPathComponent.utf8)
                hasher.update(data: Data("\(name.count):".utf8))
                hasher.update(data: name)
                hasher.update(data: try exactDigest(of: child))
            }
        } else if properties.isRegularFile == true {
            hasher.update(data: Data("file\n".utf8))
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } else {
            throw PreservationError.unsupportedFile
        }
        return Data(hasher.finalize())
    }
}
