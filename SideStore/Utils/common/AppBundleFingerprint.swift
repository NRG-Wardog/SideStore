//
//  AppBundleFingerprint.swift
//  SideStore
//
//  Content identity for preservation-mode shared payload caching.
//

import Foundation
import CryptoKit

public enum AppBundleFingerprint {
    // Distinguish these keys from upstream's old filename/size-only hashes.
    public static let contentVersionPrefix = "content-v1-"

    public static func compute(for bundleURL: URL) -> String? {
        do {
            let values = try bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let digest = try contentDigest(for: bundleURL)
            return contentVersionPrefix + digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private enum FingerprintError: Error { case unsupportedEntry }

    private static func contentDigest(for url: URL) throws -> Data {
        let fm = FileManager.default
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        // Do not follow links outside the bundle or silently omit unreadable
        // entries. Preserve such bundles for explicit compatibility review.
        guard values.isSymbolicLink != true else { throw FingerprintError.unsupportedEntry }
        var hasher = SHA256()
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
        hasher.update(data: Data("SideStore-content-v1\nmode:\(permissions)\n".utf8))
        if values.isDirectory == true {
            hasher.update(data: Data("directory\n".utf8))
            // Hidden files, signatures and profiles are part of the exact
            // payload identity; no filename/size shortcut or omission is safe.
            let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let name = Data(child.lastPathComponent.utf8)
                hasher.update(data: Data("\(name.count):".utf8))
                hasher.update(data: name)
                hasher.update(data: try contentDigest(for: child))
            }
        } else if values.isRegularFile == true {
            hasher.update(data: Data("file\n".utf8))
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } else {
            throw FingerprintError.unsupportedEntry
        }
        return Data(hasher.finalize())
    }
}
