//
//  PairingFileManager.swift
//  SideStore
//
//  Created by Magesh K on 17/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers
import MinimuxerCommon
import Darwin

public struct PairingFileMetadata: Sendable {
    public let exists: Bool
    public let size: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
}

// File-only state. Never persists or implies a live device connection.
enum V3PairingSelectionState: String {
    case selected, available, reset, missing, changed, invalid, unknown
}

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()

    // Host UI remains the sole interactive pairing owner.
    nonisolated var pairingUDID: String? {
        guard let contents = fetchPairingFile(),
              let pairing = try? parse(content: contents),
              let lockdown = pairing as? LockdownPairingFile else { return nil }
        return lockdown.udid
    }

    // Reset disables effective pairing even if an old file remains. Otherwise,
    // only proven absence qualifies; unreadable, empty, malformed or mismatched
    // records must continue through the existing diagnostic failure path.
    nonisolated var v3DeviceSetupIsUnconfigured: Bool {
        if UserDefaults.standard.isPairingReset { return true }
        for mode in [PairingProtocol.unknown, .rppairing, .lockdown] {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: pairingFileURL(for: mode).path)
                return false
            } catch let error as NSError {
                guard error.domain == NSCocoaErrorDomain,
                      [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) else { return false }
            }
        }
        guard Bundle.main.url(forResource: "ALTPairingFile", withExtension: "mobiledevicepairing") == nil else {
            return false
        }
        if let embedded = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") {
            guard let contents = embedded as? String,
                  contents == "<insert pairing file here>" else { return false }
        }
        return true
    }

    static var supportedContentTypes: [UTType] {
        var types = AppConstants.Pairing.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(contentsOf: [.propertyList, .xml])
        return types
    }

    var activeProtocol: PairingProtocol {
        minimuxerPairingProtocol()
    }

    var persistedActiveProtocol: PairingProtocol? {
        get { UserDefaults.standard.activePairingProtocol }
        set { UserDefaults.standard.activePairingProtocol = newValue }
    }

    var preferredProtocol: PairingProtocol? {
        get { UserDefaults.standard.preferredPairingProtocol }
        set { UserDefaults.standard.preferredPairingProtocol = newValue }
    }

    nonisolated func pairingFileURL(for mode: PairingProtocol) -> URL {
        let fileName: String
        switch mode {
        case .rppairing:
            fileName = AppConstants.Pairing.remotePairingFileName
        case .lockdown:
            fileName = AppConstants.Pairing.lockdownPairingFileName
        default:
            fileName = AppConstants.Pairing.legacyPairingFileName
        }
        return FileManager.default.documentsDirectory.appendingPathComponent(fileName)
    }

    nonisolated func hasPairingFile(for mode: PairingProtocol) -> Bool {
        return FileManager.default.fileExists(atPath: pairingFileURL(for: mode).path)
    }

    nonisolated func hasPairingFile() -> Bool {
        guard !UserDefaults.standard.isPairingReset else { return false }
        if let target = preferredProtocol, hasPairingFile(for: target) {
            return true
        }
        if let mode = persistedActiveProtocol, hasPairingFile(for: mode) {
            return true
        }
        return fetchPairingFile() != nil
    }

    nonisolated func metadata(for mode: PairingProtocol) -> PairingFileMetadata {
        let fileURL = pairingFileURL(for: mode)
        let path = fileURL.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return PairingFileMetadata(exists: false, size: 0, creationDate: nil, modificationDate: nil)
        }
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let creation = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        let mod = attrs[.modificationDate] as? Date
        return PairingFileMetadata(exists: true, size: size, creationDate: creation, modificationDate: mod)
    }

    nonisolated func fetchPairingFile(for mode: PairingProtocol) -> String? {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path),
           let contents = try? String(contentsOf: fileURL), !contents.isEmpty 
        {
            return contents
        }
        return nil
    }
    
    nonisolated func sanitizePairingFileFor(contents: String, pprotocol: PairingProtocol) -> String {
        guard let plistData = contents.data(using: .utf8) else {
            return contents
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String : Sendable] else {
            return contents
        }
        
        let requiredKeys: [String]
        if pprotocol == .rppairing {
            requiredKeys = [
                "private_key",
                "public_key",
                "identifier"
            ]
        } else if pprotocol == .lockdown {
            requiredKeys = [
                "WiFiMACAddress",
                "SystemBUID",
                "RootPrivateKey",
                "HostPrivateKey",
                "HostID",
                "RootCertificate",
                "UDID",
                "EscrowBag",
                "HostCertificate",
                "DeviceCertificate"
            ]
        } else {
            return contents
        }
        
        if !(requiredKeys.filter { plist[$0] == nil }.isEmpty) {
            return contents
        }
    
        var ansDict : [String : Sendable] = [:]
        for key in requiredKeys {
            ansDict[key] = plist[key]
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: ansDict, format: .xml, options: 0),
              let sanitized = String(data: data, encoding: .utf8) else { return contents }
        return sanitized
    }

    nonisolated func fetchPairingFile(preferred: PairingProtocol? = nil) -> String? {
        guard !UserDefaults.standard.isPairingReset else { return nil }
        if let preferred = preferred ?? preferredProtocol {
            if let contents = fetchPairingFile(for: preferred) {
                return sanitizePairingFileFor(contents: contents, pprotocol: preferred)
            }
            // Preserve a legacy record only if it satisfies the explicit protocol.
            if let legacy = fetchPairingFile(for: .unknown),
               (try? parse(content: legacy, preferred: preferred)) != nil {
                return sanitizePairingFileFor(contents: legacy, pprotocol: preferred)
            }
            return nil
        }
        if let persisted = persistedActiveProtocol, let contents = fetchPairingFile(for: persisted) {
            return sanitizePairingFileFor(contents: contents, pprotocol: persisted)
        }
        // Keep the current parser's legacy/composite selection semantics at boot;
        // maintenance copies never require deleting or rewriting this record.
        if let legacy = fetchPairingFile(for: .unknown) { return legacy }
        if let contents = fetchPairingFile(for: .rppairing) {
            return sanitizePairingFileFor(contents: contents, pprotocol: .rppairing)
        }
        if #available(iOS 26.4, *), let contents = fetchPairingFile(for: .lockdown) {
            return sanitizePairingFileFor(contents: contents, pprotocol: .lockdown)
        }
        // Existing host packaging can still supply the legacy bundled record.
        if let url = Bundle.main.url(forResource: "ALTPairingFile", withExtension: "mobiledevicepairing"),
           let contents = try? String(contentsOf: url, encoding: .utf8), !contents.isEmpty {
            return contents
        }
        if let contents = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String,
           !contents.isEmpty, !contents.contains("insert pairing file here") {
            return contents
        }
        return nil
    }

    @discardableResult
    nonisolated func parse(content: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        try PairingFileParser.parse(content: content, preferred: preferred)
    }

    @discardableResult
    func savePairingFile(contents: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        let parsed = try parse(content: contents, preferred: preferred)
        let destinationURL = pairingFileURL(for: parsed.mode)
        // Atomic replacement keeps the previous file intact if writing fails.
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        debugLog("[PairingFile] Pairing file saved; path and identity omitted.")
        UserDefaults.standard.isPairingReset = false
        return parsed
    }

    func inspectPairingFile(from url: URL) throws -> (content: String, file: any PairingFile) {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let parsed = try parse(content: content, preferred: nil)
        return (content, parsed)
    }

    func importPairingFile(contents: String, preferred: PairingProtocol? = nil) throws {
        // Explicit imports select their verified protocol, unlike maintenance or
        // ordinary saves. An intentional preferred protocol still takes priority.
        let selectedProtocol = preferred ?? preferredProtocol
        let inspected = try parse(content: contents, preferred: selectedProtocol)
        if let selectedProtocol, inspected.mode != selectedProtocol {
            // Some parser versions may fall back to another supported protocol.
            // Reject that mismatch before saving or changing active selection.
            throw CocoaError(.fileReadCorruptFile)
        }
        let parsed = try savePairingFile(contents: contents, preferred: selectedProtocol)
        guard parsed.mode == inspected.mode,
              fetchPairingFile(for: parsed.mode) == contents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        persistedActiveProtocol = parsed.mode
    }

    func importPairingFile(from url: URL, preferred: PairingProtocol? = nil) throws {
        let (content, _) = try inspectPairingFile(from: url)
        try importPairingFile(contents: content, preferred: preferred)
    }

    // Explicit placement only. Never called by fetch/status/maintenance/boot.
    // Reuse import's parser and preferred-protocol rules, but do not replace a
    // different protocol file. Manual import remains the replacement workflow.
    struct PlacedImport {
        let directory: V3PlacedPairingDirectory
        let source: V3PlacedPairingDirectory.Snapshot
        let destination: V3PlacedPairingDirectory.Snapshot?
        let destinationName: String
        let content: String
        let mode: PairingProtocol
        let expectedUDID: String?
        let wasReset: Bool
        let active: PairingProtocol?
        let preferred: PairingProtocol?

        var isCurrentSelection: Bool {
            !wasReset && active == mode && (preferred == nil || preferred == mode) &&
                destination?.data == source.data
        }
    }

    // V3_PAIRING_SAVED_SELECTION_V1: read-only and recomputed on each snapshot.
    // The protocol preference is not an adoption receipt: only safe, stable
    // readback plus parsing permits the file-only selected label.
    func currentSelectionState() -> V3PairingSelectionState {
        if UserDefaults.standard.isPairingReset { return .reset }
        let active = persistedActiveProtocol
        let preferred = preferredProtocol
        do {
            let directory = try V3PlacedPairingDirectory(root: FileManager.default.documentsDirectory)
            let source = try directory.read(AppConstants.Pairing.legacyPairingFileName)
            if let active, active != .unknown {
                if let preferred, preferred != active { return .changed }
                let name = pairingFileURL(for: active).lastPathComponent
                guard let selected = try directory.read(name) else { return .missing }
                guard let content = String(data: selected.data, encoding: .utf8),
                      let parsed = try? parse(content: content, preferred: preferred ?? active),
                      parsed.mode == active else { return .invalid }
                guard !UserDefaults.standard.isPairingReset,
                      persistedActiveProtocol == active, preferredProtocol == preferred,
                      try directory.read(name) == selected,
                      try directory.read(AppConstants.Pairing.legacyPairingFileName) == source else {
                    return .unknown
                }
                if let source, source.data != selected.data { return .changed }
                return .selected
            }
            guard let source else { return .unknown }
            guard let content = String(data: source.data, encoding: .utf8),
                  let parsed = try? parse(content: content, preferred: preferred),
                  parsed.mode != .unknown, preferred == nil || parsed.mode == preferred else { return .invalid }
            guard !UserDefaults.standard.isPairingReset,
                  persistedActiveProtocol == active, preferredProtocol == preferred,
                  try directory.read(AppConstants.Pairing.legacyPairingFileName) == source else { return .unknown }
            return .available
        } catch {
            return .unknown
        }
    }

    func preparePlacedImport() throws -> PlacedImport {
        let directory = try V3PlacedPairingDirectory(root: FileManager.default.documentsDirectory)
        let source = try directory.read(AppConstants.Pairing.legacyPairingFileName)
        guard let source, let content = String(data: source.data, encoding: .utf8), !content.isEmpty else {
            throw V3PlacedPairingError.missingOrInvalid
        }
        let selected = preferredProtocol
        let parsed: any PairingFile
        do { parsed = try parse(content: content, preferred: selected) }
        catch { throw V3PlacedPairingError.missingOrInvalid }
        guard parsed.mode != .unknown, selected == nil || parsed.mode == selected else {
            throw V3PlacedPairingError.missingOrInvalid
        }
        let name = pairingFileURL(for: parsed.mode).lastPathComponent
        let destination = try directory.read(name)
        // Do not overwrite an unrelated existing record, even after a reset
        // whose old-file deletion may have failed.
        guard destination == nil || destination?.data == source.data else {
            throw V3PlacedPairingError.conflictingFile
        }
        return PlacedImport(directory: directory, source: source, destination: destination,
            destinationName: name, content: content, mode: parsed.mode,
            expectedUDID: (parsed as? LockdownPairingFile)?.udid,
            wasReset: UserDefaults.standard.isPairingReset,
            active: persistedActiveProtocol, preferred: selected)
    }

    func validatePlacedImport(_ plan: PlacedImport) throws {
        guard UserDefaults.standard.isPairingReset == plan.wasReset,
              persistedActiveProtocol == plan.active, preferredProtocol == plan.preferred,
              try plan.directory.read(AppConstants.Pairing.legacyPairingFileName) == plan.source,
              try plan.directory.read(plan.destinationName) == plan.destination else {
            throw V3PlacedPairingError.stale
        }
    }

    func validateCommittedPlacedImport(_ plan: PlacedImport) throws {
        guard !UserDefaults.standard.isPairingReset, persistedActiveProtocol == plan.mode,
              preferredProtocol == plan.preferred,
              try plan.directory.read(AppConstants.Pairing.legacyPairingFileName) == plan.source,
              try plan.directory.read(plan.destinationName)?.data == plan.source.data else {
            throw V3PlacedPairingError.stale
        }
    }

    func commitPlacedImport(_ plan: PlacedImport) throws {
        try Task.checkCancellation()
        try validatePlacedImport(plan)
        let parsed = try parse(content: plan.content, preferred: plan.preferred)
        guard parsed.mode == plan.mode else { throw V3PlacedPairingError.stale }
        // Publish a verified copy without replacing any file. The final reset
        // and active-protocol changes happen together, after verified readback.
        do {
            try plan.directory.publish(plan.source.data, to: plan.destinationName, existing: plan.destination) {
                try Task.checkCancellation()
                guard UserDefaults.standard.isPairingReset == plan.wasReset,
                      self.persistedActiveProtocol == plan.active, self.preferredProtocol == plan.preferred,
                      try plan.directory.read(AppConstants.Pairing.legacyPairingFileName) == plan.source else {
                    throw V3PlacedPairingError.stale
                }
                self.persistedActiveProtocol = plan.mode
                UserDefaults.standard.isPairingReset = false
            }
        } catch {
            if error as? V3PlacedPairingError == .cleanupFailed,
               UserDefaults.standard.isPairingReset == plan.wasReset,
               persistedActiveProtocol == plan.active, preferredProtocol == plan.preferred {
                // Failed removal of our own published file is uncertain. Keep
                // it disabled without overwriting a newer selection or file.
                UserDefaults.standard.isPairingReset = true
            }
            throw error
        }
    }

    func deletePairingFile(for mode: PairingProtocol) {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
            debugLog("[PairingFile] Explicit pairing-file removal completed; path omitted.")
        }
        if mode == persistedActiveProtocol {
            persistedActiveProtocol = nil
        }
    }

    func resetAllPairingFiles() {
        let fm = FileManager.default
        let files = [
            AppConstants.Pairing.lockdownPairingFileName,
            AppConstants.Pairing.remotePairingFileName,
            AppConstants.Pairing.legacyPairingFileName
        ]
        for name in files {
            let path = fm.documentsDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
        UserDefaults.standard.isPairingReset = true
        persistedActiveProtocol = nil
        debugLog("[PairingFile] Reset all pairing files.")
    }
}

// V3_PLACED_PAIRING_TRANSACTION_V1: all failure messages are finite. File bytes,
// paths, device identifiers, parser descriptions and keys never leave the service.
enum V3PlacedPairingError: Error, Equatable {
    case missingOrInvalid, unsafeFile, conflictingFile, stale, startupFailed, cleanupFailed
}

final class V3PlacedPairingDirectory {
    static let maximumBytes = 4 * 1024 * 1024
    struct Snapshot: Equatable {
        let data: Data
        let device: UInt64
        let inode: UInt64
        let modified: String
    }
    private let root: URL
    private let descriptor: Int32
    private let identity: String

    init(root: URL) throws {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        // The owned Documents directory itself must not be a symlink. Resolve
        // only its sandbox parent (iOS may alias /var to /private/var).
        let expected = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent).standardizedFileURL
        guard canonical.path == expected.path else { throw V3PlacedPairingError.unsafeFile }
        let fd = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw V3PlacedPairingError.unsafeFile }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); throw V3PlacedPairingError.unsafeFile }
        self.root = canonical
        self.descriptor = fd
        self.identity = "\(info.st_dev):\(info.st_ino)"
    }
    deinit { close(descriptor) }

    private func requireCurrentDirectory() throws {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw V3PlacedPairingError.stale }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, "\(info.st_dev):\(info.st_ino)" == identity else {
            throw V3PlacedPairingError.stale
        }
    }

    private func stamp(_ info: stat) -> String {
        "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    func read(_ name: String) throws -> Snapshot? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw V3PlacedPairingError.unsafeFile
        }
        try requireCurrentDirectory()
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw V3PlacedPairingError.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= Self.maximumBytes else {
            throw V3PlacedPairingError.unsafeFile
        }
        var data = Data()
        while data.count <= Self.maximumBytes {
            guard let chunk = try handle.read(upToCount: min(64 * 1024, Self.maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        var after = stat()
        guard data.count == before.st_size, data.count <= Self.maximumBytes,
              fstat(fd, &after) == 0, before.st_ino == after.st_ino,
              before.st_dev == after.st_dev, stamp(before) == stamp(after) else {
            throw V3PlacedPairingError.stale
        }
        var pathInfo = stat()
        guard fstatat(descriptor, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              pathInfo.st_ino == after.st_ino, pathInfo.st_dev == after.st_dev,
              stamp(pathInfo) == stamp(after) else { throw V3PlacedPairingError.stale }
        try requireCurrentDirectory()
        return Snapshot(data: data, device: UInt64(after.st_dev), inode: UInt64(after.st_ino), modified: stamp(after))
    }

    // A verified private staging file is hard-linked with exclusive destination
    // creation. No replacing rename/write, rollback of unrelated files, or await
    // is permitted in this final commit section.
    func publish(_ data: Data, to name: String, existing: Snapshot?, commit: () throws -> Void) throws {
        guard try read(name) == existing else { throw V3PlacedPairingError.stale }
        if let existing {
            guard existing.data == data else { throw V3PlacedPairingError.conflictingFile }
            try commit()
            return
        }
        let staging = ".placed-pairing-" + UUID().uuidString
        let fd = openat(descriptor, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw V3PlacedPairingError.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(descriptor, staging, 0) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard let staged = try read(staging), staged.data == data else { throw V3PlacedPairingError.stale }
        try Task.checkCancellation()
        try requireCurrentDirectory()
        guard linkat(descriptor, staging, descriptor, name, 0) == 0 else { throw V3PlacedPairingError.conflictingFile }
        do {
            guard let stored = try read(name), stored.data == data,
                  stored.inode == staged.inode, stored.device == staged.device else { throw V3PlacedPairingError.stale }
            try commit()
        } catch {
            // Remove only the file this transaction created, never a newer placement.
            var current = stat()
            let inspected = fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW)
            if inspected == 0 {
                if UInt64(current.st_ino) == staged.inode, UInt64(current.st_dev) == staged.device {
                    guard unlinkat(descriptor, name, 0) == 0 else { throw V3PlacedPairingError.cleanupFailed }
                }
            } else if errno != ENOENT { throw V3PlacedPairingError.cleanupFailed }
            throw error
        }
    }
}
