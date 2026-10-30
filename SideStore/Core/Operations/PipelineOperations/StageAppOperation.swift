//
//  StageAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 31/7/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import SideSign

final class StageAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[StageAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[StageAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)
        
        if let binding = context.legacyReplacementBinding {
            try await context.validateLegacyReplacementAdmission()
            guard let source = context.targetAppBundle,
                  AppBundleFingerprint.compute(for: source.fileURL) == binding.sourceTreeDigest,
                  AppBundleFingerprint.computeOriginalCacheKey(for: source.fileURL) == binding.sourceFingerprint else {
                throw OperationError.invalidParameters("The confirmed replacement input changed.")
            }
            try context.validateLegacyReplacementBundle(source, signed: false)
            let root = context.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            let destination = root.appendingPathComponent("LegacyReplacement.app", isDirectory: true)
            guard source.fileURL.resolvingSymlinksInPath().standardizedFileURL != destination,
                  !FileManager.default.fileExists(atPath: destination.path) else {
                throw OperationError.invalidParameters("The owned replacement staging destination is not empty.")
            }
            try FileManager.default.copyItem(at: source.fileURL, to: destination)
            guard AppBundleFingerprint.compute(for: destination) == binding.sourceTreeDigest,
                  let staged = ALTApplication(fileURL: destination) else {
                throw OperationError.invalidParameters("The replacement staging copy could not be verified.")
            }
            try context.validateLegacyReplacementBundle(staged, signed: false)
            try await context.validateLegacyReplacementAdmission()
            context.targetAppBundle = staged
            self.setProgress(100)
            return staged
        }

        if let appBundle = self.context.targetAppBundle,
           appBundle.bundle.bundleURL.path.contains("SideBackup") || appBundle.bundle.bundleURL.path.contains("AltBackup"),
           let installedApp = self.context.installedApp {
            self.context.targetAppBundle = ALTApplication(fileURL: installedApp.fileURL)
        }
        
        if self.context.targetAppBundle == nil, let installedApp = self.context.installedApp {
            self.context.targetAppBundle = ALTApplication(fileURL: installedApp.fileURL)
        }
        
        guard let appBundle = self.context.targetAppBundle else {
            throw OperationError.invalidParameters("StageAppOperation: context.appBundle is nil")
        }
        
        let fileURL = appBundle.fileURL
        let tempDir = self.context.temporaryDirectory
        
        self.setProgress(30)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        if fileURL.path.hasPrefix(tempDir.path) {
            debugLog("[StageAppOperation] App is already in temporary directory: \(fileURL)")
            self.setProgress(100)
            return appBundle
        }
        
        let destinationURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
        debugLog("[StageAppOperation] Copying cached app from \(fileURL) to \(destinationURL)")
        
        self.setProgress(60)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            debugLog("[StageAppOperation] Removing pre-existing app bundle at destination: \(destinationURL)")
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        self.setProgress(80)
        debugLog("[StageAppOperation] Copying item from \(fileURL) to \(destinationURL)")
        try FileManager.default.copyItem(at: fileURL, to: destinationURL)
        debugLog("[StageAppOperation] Successfully copied app bundle to destination.")
        
        guard let stagedAppBundle = ALTApplication(fileURL: destinationURL) else {
            throw OperationError.missingAppBundle(reason: "Could not load staged app bundle at '\(destinationURL.lastPathComponent)'")
        }
        
        self.context.targetAppBundle = stagedAppBundle
        self.setProgress(100)
        return stagedAppBundle
    }
}
