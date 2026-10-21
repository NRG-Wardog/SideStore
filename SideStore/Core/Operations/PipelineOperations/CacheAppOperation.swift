//
//  CacheAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation

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
        guard let signature = AppBundleFingerprint.compute(for: bundleURL) else {
            throw OperationError.invalidApp(reason: "The app payload could not be verified without following unsupported filesystem entries. Existing caches were preserved.")
        }
        let fm = FileManager.default
        let targetFileURL = InstalledApp.payloadURL(forSignature: signature)
        let rootPath = InstalledApp.appsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard targetFileURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath) else {
            throw OperationError.invalidApp(reason: "The cache destination is outside the app cache. Existing caches were preserved.")
        }
        if fm.fileExists(atPath: targetFileURL.path) {
            guard AppBundleFingerprint.compute(for: targetFileURL) == signature else {
                throw OperationError.invalidApp(reason: "An existing shared payload conflicts with its content key. It was not replaced. Keep the cache for review.")
            }
            return (signature, targetFileURL)
        }

        let parentDir = targetFileURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        let staging = parentDir.appendingPathComponent(".preservation-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) } // Only our unpublished scratch copy.
        try fm.copyItem(at: bundleURL, to: staging)
        guard AppBundleFingerprint.compute(for: staging) == signature,
              AppBundleFingerprint.compute(for: bundleURL) == signature else {
            throw OperationError.invalidApp(reason: "The app payload changed or could not be copied completely. Original files and existing caches were preserved.")
        }
        // Never use shouldReplace here. A concurrent publication must either
        // verify identically or fail without replacing either writer's payload.
        // Needs proper iOS concurrent-publication fault testing before release.
        do {
            try fm.moveItem(at: staging, to: targetFileURL)
        } catch {
            guard fm.fileExists(atPath: targetFileURL.path),
                  AppBundleFingerprint.compute(for: targetFileURL) == signature else {
                throw error
            }
        }
        guard AppBundleFingerprint.compute(for: targetFileURL) == signature else {
            throw OperationError.invalidApp(reason: "The published cache did not verify. Original files were retained; the cache was not replaced.")
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
