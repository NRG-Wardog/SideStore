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

public struct PairingFileMetadata: Sendable {
    public let exists: Bool
    public let size: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
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

    func importPairingFile(from url: URL, preferred: PairingProtocol? = nil) throws {
        let (content, _) = try inspectPairingFile(from: url)
        let parsed = try savePairingFile(contents: content, preferred: preferred)
        persistedActiveProtocol = parsed.mode
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
