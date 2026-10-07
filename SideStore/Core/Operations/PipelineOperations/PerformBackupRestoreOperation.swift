//
//  BackupRestoreAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 5/12/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import SideSign

extension PerformBackupRestoreOperation {
    enum Action: String {
        case backup
        case restore
    }
}

final class PerformBackupRestoreOperation: BasePipelineOperation<InstallAppOperationContext, URL>, @unchecked Sendable {
    let action: Action
    
    private var appName: String?
    
    init(action: Action, context: InstallAppOperationContext) throws {
        self.action = action
        try super.init(context: context)
    }
    
    override func execute(parentProgress: Progress?) async throws -> URL {
        let startTime = CFAbsoluteTimeGetCurrent()
        self.debugLog("[BackupRestoreAppOperation] execute() started. Action: \(action.rawValue)")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            self.debugLog("[BackupRestoreAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        guard let installedApp = context.installedApp else {
            self.debugLog("[BackupRestoreAppOperation] Error: context.installedApp is nil")
            throw OperationError.invalidParameters("BackupRestoreAppOperation.execute: context.installedApp is nil")
        }
        
        guard let context = installedApp.managedObjectContext else {
            throw OperationError.invalidParameters("BackupRestoreAppOperation: installedApp.managedObjectContext is nil")
        }
        let (bundleID, fileURL, name, openAppURL) = context.performAndWait {
            (installedApp.bundleIdentifier, installedApp.fileURL, installedApp.name, installedApp.openAppURL)
        }
        
        self.debugLog("[BackupRestoreAppOperation] Ready to open app and observe backup. InstalledApp: \(bundleID)")
        try await self.openAppAndObserve(installedApp: installedApp, bundleIdentifier: bundleID, name: name, openAppURL: openAppURL)
        self.debugLog("[BackupRestoreAppOperation] execute() completed successfully.")
        return fileURL
    }
    
    private func constructBackupURLs(bundleIdentifier: String, name: String, openAppURL: URL, callback: V3BackupCallbackIdentity?) throws -> (openURL: URL, returnURL: URL) {
        self.appName = name
        
        let appGroupBundleID = Bundle.Info.activeBundleIdentifier
        guard let altstoreOpenURL = URL(string: "sidestore://")
        else {
            throw OperationError.openAppFailed(name: name)
        }

        var returnURLComponents = URLComponents(url: altstoreOpenURL, resolvingAgainstBaseURL: false)
        returnURLComponents?.host = "appBackupResponse"
        returnURLComponents?.queryItems = [URLQueryItem(name: "targetBundleID", value: appGroupBundleID)] + (callback?.queryItems ?? [])
        guard let returnURL = returnURLComponents?.url else { throw OperationError.openAppFailed(name: name) }

        var queryItems = [URLQueryItem(name: "returnURL", value: returnURL.absoluteString)]
        if OperationsLoggingControl.isLoggingEnabled(for: Self.self) {
            queryItems.append(URLQueryItem(name: "verbose", value: "true"))
        }
        if UserDefaults.standard.skipNonCopyableBackupFiles {
            queryItems.append(URLQueryItem(name: "skipNonCopyable", value: "true"))
        }

        var openURLComponents = URLComponents()
        openURLComponents.scheme = openAppURL.scheme
        openURLComponents.host = self.action.rawValue
        openURLComponents.queryItems = queryItems
        
        guard let openURL = openURLComponents.url else { throw OperationError.openAppFailed(name: name) }
        return (openURL, returnURL)
    }

    private func mapBackupError(_ error: Error) -> Error {
        let appName = self.appName ?? self.context.bundleIdentifier
        
        switch (error, self.action) {
        case (let error as NSError, _) where (self.context.error as NSError?) == error: fallthrough
        case (is CancellationError, _):
            return error
            
        case (let error as NSError, .backup):
            let localizedFailure = String(format: NSLocalizedString("Could not back up “%@”.", comment: ""), appName)
            return error.withLocalizedFailure(localizedFailure)
            
        case (let error as NSError, .restore):
            let localizedFailure = String(format: NSLocalizedString("Could not restore “%@”.", comment: ""), appName)
            return error.withLocalizedFailure(localizedFailure)
        }
    }

    @MainActor
    private func openApp(url: URL) async -> Bool {
        self.debugLog("[BackupRestoreAppOperation] opening backup application")
        if let handler = self.context.handler as? V3HeadlessPipelineHandler,
           !handler.backupCallbackMayOpen() { return false }
        let currentTime = CFAbsoluteTimeGetCurrent()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(url, options: [:]) { success in
                let elapsedTime = CFAbsoluteTimeGetCurrent() - currentTime
                self.debugLog("[BackupRestoreAppOperation] openApp() completion handler success: \(success), elapsedTime: \(elapsedTime)s")
                if success {
                    continuation.resume(returning: true)
                } else if elapsedTime < 0.5 {
                    self.debugLog("[BackupRestoreAppOperation] Failed to open app too quickly, retrying after a few seconds...")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if let handler = self.context.handler as? V3HeadlessPipelineHandler,
                           !handler.backupCallbackMayOpen() {
                            continuation.resume(returning: false)
                            return
                        }
                        UIApplication.shared.open(url, options: [:]) { retrySuccess in
                            self.debugLog("[BackupRestoreAppOperation] openApp() retry completion handler success: \(retrySuccess)")
                            continuation.resume(returning: retrySuccess)
                        }
                    }
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func openAppAndObserve(installedApp: InstalledApp, bundleIdentifier: String, name: String, openAppURL: URL) async throws {
        // V3_BACKUP_CALLBACK_OWNER_V1: mint the one-shot callback before
        // opening SideBackup; only its owning session may consume the result.
        let headlessHandler = self.context.handler as? V3HeadlessPipelineHandler
        let callback = try await headlessHandler?.beginBackupCallback(action: action.rawValue)
        defer {
            if let callback, let headlessHandler {
                Task { @MainActor in headlessHandler.endBackupCallback(callback) }
            }
        }
        let (openURL, returnURL) = try self.constructBackupURLs(bundleIdentifier: bundleIdentifier, name: name, openAppURL: openAppURL, callback: callback)
        self.debugLog("[BackupRestoreAppOperation] prepared backup callback")
        
        self.debugLog("[BackupRestoreAppOperation] Starting observation...")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var applicationWillReturnObserver: NSObjectProtocol?
            var backupResponseObserver: NSObjectProtocol?
            var hasResumed = false

            let removeObserversAndResume = { (result: Result<Void, Error>) -> Bool in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return false }
                hasResumed = true
                
                if let observer = applicationWillReturnObserver {
                    NotificationCenter.default.removeObserver(observer)
                    applicationWillReturnObserver = nil
                }
                if let observer = backupResponseObserver {
                    NotificationCenter.default.removeObserver(observer)
                    backupResponseObserver = nil
                }
                
                continuation.resume(with: result)
                return true
            }

            // A foreground transition does not establish whether an external
            // copy stopped. Headless cancellation keeps the operation/journal
            // owner until the actual callback or explicit device reconciliation.
            var appWillReturnObs: NSObjectProtocol?
            if callback == nil {
                appWillReturnObs = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                self.debugLog("[BackupRestoreAppOperation] willEnterForegroundNotification received. Starting 5-second grace period timer...")
                Task {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    self.debugLog("[BackupRestoreAppOperation] 5-second timer expired without receiving backup completion response. Timing out.")
                    await AppDelegate.dumpSideBackupLogsIfNeeded()
                    _ = removeObserversAndResume(.failure(OperationError.timedOut))
                }
            }
            
            }

            let backupRespObs = NotificationCenter.default.addObserver(
                forName: AppDelegate.appBackupDidFinish,
                object: nil,
                queue: nil
            ) { notification in
                if let callback,
                   notification.userInfo?["v3BackupNonce"] as? String != callback.nonce { return }
                self.debugLog("[BackupRestoreAppOperation] correlated backup result received")
                Task.detached {
                    await AppDelegate.dumpSideBackupLogsIfNeeded()
                    
                    let result = notification.userInfo?[AppDelegate.appBackupResultKey] as? Result<Void, Error> ?? .failure(OperationError.unknownResult)
                    let mappedResult = result.mapError { self.mapBackupError($0) }
                    self.debugLog("[BackupRestoreAppOperation] Resuming continuation with mapped result: \(mappedResult)")
                    
                    let didResume = removeObserversAndResume(mappedResult)
                    if didResume, case .success = mappedResult {
                        self.setProgress(self.progress.completedUnitCount + 1)
                    }
                }
            }

            lock.withLock {
                applicationWillReturnObserver = appWillReturnObs
                backupResponseObserver = backupRespObs
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let openedSuccessfully = await self.openApp(url: openURL)
                if !openedSuccessfully {
                    self.debugLog("[BackupRestoreAppOperation] Failed to open target application. Resuming with error.")
                    _ = removeObserversAndResume(.failure(OperationError.openAppFailed(name: name)))
                }
            }
        }
    }
}
