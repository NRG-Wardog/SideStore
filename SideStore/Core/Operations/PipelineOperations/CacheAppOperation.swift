//
//  CacheAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation
import Darwin

final class CacheAppOperation: BasePipelineOperation<InstallAppOperationContext, URL?>, @unchecked Sendable {

    override func execute(parentProgress: Progress?) async throws -> URL? {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[CacheAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[CacheAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        guard let appBundle = context.targetAppBundle else {
            debugLog("[CacheAppOperation] context.appBundle is nil")
            self.setProgress(100)
            return nil
        }

        self.setProgress(40)
        let (signature, targetFileURL) = try Self.cachePayload(for: appBundle.fileURL)
        self.context.appBundleFingerprint = signature
        self.setProgress(100)
        return targetFileURL
    }

    @discardableResult
    static func cachePayload(for bundleURL: URL) throws -> (signature: String, targetFileURL: URL) {
        guard let signature = AppBundleFingerprint.computeOriginalCacheKey(for: bundleURL) else {
            throw OperationError.invalidApp(reason: "Failed to compute app bundle fingerprint for '\(bundleURL.lastPathComponent)'")
        }

        // Resolve the trusted, existing Apps root once. A missing descendant
        // cannot reliably resolve aliases in that root on its own.
        let appsDirectoryURL = InstalledApp.appsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let targetFileURL = appsDirectoryURL.appendingPathComponent("Payloads")
            .appendingPathComponent(signature).appendingPathComponent("App.app")
        // Retain containment and no-overwrite copy boundaries while restoring
        // upstream cache key/reuse behavior. Caches are not reset or pruned.
        // Resolving a nonexistent App.app may leave an existing symlink ancestor
        // unresolved. Inspect only the three cache components below Apps, in
        // order, without following their final entry (including dangling links).
        let cachePathComponents = [
            targetFileURL.deletingLastPathComponent().deletingLastPathComponent(),
            targetFileURL.deletingLastPathComponent(),
            targetFileURL
        ]
        for componentURL in cachePathComponents {
            var fileStatus = stat()
            let status = componentURL.path.withCString { lstat($0, &fileStatus) }
            if status == 0 {
                guard (fileStatus.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
                    throw OperationError.invalidApp(reason: "The cache destination contains a symbolic link. Existing caches were preserved.")
                }
            } else {
                let errorCode = errno
                guard errorCode == ENOENT else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: nil)
                }
            }
        }
        let rootPath = appsDirectoryURL.path + "/"
        guard targetFileURL.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw OperationError.invalidApp(reason: "The cache destination is outside the app cache. Existing caches were preserved.")
        }
        if !FileManager.default.fileExists(atPath: targetFileURL.path) {
            let parentDir = targetFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.copyItem(at: bundleURL, to: targetFileURL, shouldReplace: false)
        } else {
        }

        return (signature, targetFileURL)
    }

    static func pruneUnusedCaches(activeSignatures: Set<String> = [], activeBundleIDs: Set<String>, isActivelyManaging: (String) -> Bool) {
        // Preservation validation: shared payload auto-pruning is intentionally
        // disabled. A verified cache may still be awaiting its CoreData commit,
        // or be retained after a migration failure. User-requested cleanup is
        // separate and remains available; no old maintenance pass is completed.
        _ = activeSignatures

        // 2. Prune unused instance directories in Apps/
        do {
            let cachedAppDirectories = try FileManager.default.contentsOfDirectory(
                at: InstalledApp.appsDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            )
            for appDirectory in cachedAppDirectories {
                do {
                    let resourceValues = try appDirectory.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
                    guard let isDirectory = resourceValues.isDirectory, let bundleID = resourceValues.name else { continue }
                    if bundleID == "Payloads" { continue }
                    
                    if isDirectory && !activeBundleIDs.contains(bundleID) && !isActivelyManaging(bundleID) {
                        SideStore.debugLog("[CacheAppOperation] DELETING CACHED APP: \(bundleID)")
                        try FileManager.default.removeItem(at: appDirectory)
                    }
                } catch {
                    SideStore.debugLog("[CacheAppOperation] Failed to remove cached app directory: \(error)")
                }
            }
        } catch {
            SideStore.debugLog("[CacheAppOperation] Failed to remove cached apps: \(error)")
        }
    }
}
