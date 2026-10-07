//
//  BackgroundRefreshAppsOperation.swift
//  AltStore
//
//  Created by Riley Testut on 7/6/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import CoreData


private extension CFNotificationName {
    static let requestAppState = CFNotificationName("com.altstore.RequestAppState" as CFString)
    static let appIsRunning = CFNotificationName("com.altstore.AppState.Running" as CFString)
    
    static func requestAppState(for appID: String) -> CFNotificationName {
        let name = String(CFNotificationName.requestAppState.rawValue) + "." + appID
        return CFNotificationName(name as CFString)
    }
    
    static func appIsRunning(for appID: String) -> CFNotificationName {
        let name = String(CFNotificationName.appIsRunning.rawValue) + "." + appID
        return CFNotificationName(name as CFString)
    }
}

private let ReceivedApplicationState: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void = { (center, observer, name, object, userInfo) in
    guard let name = name, let observer = observer else { return }
    
    let operation = unsafeBitCast(observer, to: BackgroundRefreshAppsOperation.self)
    operation.receivedApplicationState(notification: name)
}

final class BackgroundRefreshAppsOperation: BaseStandaloneOperation<OperationContext, [String: Result<InstalledApp, Error>]>, @unchecked Sendable {
    let installedApps: [InstalledApp]
    
    var presentsFinishedNotification: Bool = true
    var ignoresServerNotFoundError: Bool = true
    
    private let refreshIdentifier: String = UUID().uuidString
    private var runningApplications: Set<String> = []
    private let refreshGroupLock = NSLock()
    private var activeRefreshGroup: RefreshGroup?
    
    init(installedApps: [InstalledApp], context: OperationContext) throws {
        self.installedApps = installedApps
        try super.init(context: context)
    }

    override func cancel() {
        super.cancel()
        self.refreshGroupLock.lock()
        let group = self.activeRefreshGroup
        self.refreshGroupLock.unlock()
        group?.cancel()
    }
    
    override func execute(parentProgress: Progress?) async throws -> [String: Result<InstalledApp, Error>] {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[BackgroundRefreshAppsOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[BackgroundRefreshAppsOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)
        
        let dbContext = self.context.dbBackgroundContext
        
        guard !self.installedApps.isEmpty else {
            let error = OperationError.noInstalledApps
            self.scheduleFinishedRefreshingNotification(for: .failure(error), delay: 0)
            throw error
        }

        // Match the upstream cached-session and silent sign-in credential paths.
        // This checks available authentication material, not server validity.
        let auth = AuthManager.shared
        let hasReusableSession = auth.v3CachedSessionMatchesCurrentRoute(auth.session) && auth.team != nil && CertificateManager.shared.activeCertificate != nil
        // LC_AUTO_REFRESH_CREDENTIAL_SNAPSHOT_V1: each credential route uses one locked Keychain epoch.
        let authSnapshot: LCEmbeddedAuthenticationSnapshot?
        if hasReusableSession {
            authSnapshot = nil
        } else {
            do {
                authSnapshot = try Keychain.shared.authenticationSnapshot()
            } catch {
                let error = Keychain.shared.embeddedAuthenticationFailure(error)
                debugLog("[AUTO_REFRESH] AUTH_PREFLIGHT_FAIL reason=keychain_access")
                self.scheduleFinishedRefreshingNotification(for: .failure(error), delay: 0)
                throw error
            }
        }
        let hasPasswordCredentials = authSnapshot?.appleIDEmailAddress != nil && authSnapshot?.appleIDPassword != nil
        let hasTokenCredentials = authSnapshot?.appleIDAdsid != nil && authSnapshot?.appleIDXcodeToken != nil
        debugLog("[AUTO_REFRESH] AUTH_CREDENTIAL_VISIBILITY password_path=\(hasPasswordCredentials) token_path=\(hasTokenCredentials) session_path=\(hasReusableSession)")
        guard hasPasswordCredentials || hasTokenCredentials || hasReusableSession else {
            // LC_AUTH_CREDENTIALS_MISSING_V1: key access failures are classified at the throwing read.
            let error = NSError(domain: "com.SideStore.Authentication", code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "The refresh process cannot access saved sign-in credentials or a reusable session. Open SideStore to check your account."])
            debugLog("[AUTO_REFRESH] AUTH_PREFLIGHT_FAIL reason=no_accessible_authentication_path")
            self.scheduleFinishedRefreshingNotification(for: .failure(error), delay: 0)
            throw error
        }
        debugLog("[AUTO_REFRESH] AUTH_PREFLIGHT_PASS")

        if UserDefaults.standard.enableEMPforWireguard {
            try await startEMProxy()
        }
        
        defer {
            dbContext.perform {
                self.stopListeningForRunningApps()
            }
        }
        
        do {
            if #available(iOS 17, *) {
                // TODO: iOS 17 and above have a new JIT implementation that is completely broken in SideStore :(
            }

            await dbContext.perform {
                self.startListeningForRunningApps()
            }

            // Wait for 1 second (1 now, 1 later in FindServerOperation) to:
            // a) give us time to discover AltServers
            // b) give other processes a chance to respond to requestAppState notification
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard !self.isCancelled else { throw OperationError.cancelled }

            // V3_RUNTIME_SHARED_REFRESH_STORE_V1: this operation writes the
            // verification manifest, the host-handoff record and the expected
            // run ID that the host reads back from the shared App Group. A
            // `.standard` or nil store would write them where no other process
            // can read them, so an unavailable shared store fails the run now,
            // before any work, instead of completing unobserved.
            let refreshDefaults: UserDefaults
            do {
                refreshDefaults = try automaticRefreshDefaults()
            } catch {
                self.debugLog("[AUTO_REFRESH] SHARED_STORE_UNAVAILABLE failure_category=sharedStoreUnavailable")
                throw error
            }
            let expectedRunID = refreshDefaults.string(forKey: "liveContainerAutoRefreshExpectedRunID")
            let manualRunID = refreshDefaults.string(forKey: "liveContainerAutoRefreshActiveManualOriginRunID")
            let manualOrigin = refreshDefaults.string(forKey: "liveContainerAutoRefreshActiveManualOrigin")
            let isCorrelatedManualRun = expectedRunID != nil && expectedRunID == manualRunID &&
                UUID(uuidString: expectedRunID ?? "") != nil &&
                ["home", "refreshManager", "setupAssistant", "deadlineAlarm", "vpnReturn", "manualUnknown"].contains(manualOrigin ?? "")

            let targetPlan = CombinedRefreshTargetPolicy.plan(
                requestedIDs: self.installedApps.map { $0.bundleIdentifier },
                runningIDs: self.runningApplications,
                isCorrelatedManualRun: isCorrelatedManualRun)
            let attemptedIDs = Set(targetPlan.attemptedIDs)
            let filteredApps = await dbContext.perform {
                // User initiated host refresh follows the manager's full target policy.
                // Scheduled background runs continue to skip apps currently in use.
                return self.installedApps.filter { attemptedIDs.contains($0.bundleIdentifier) }
            }
            debugLog("[AUTO_REFRESH] TARGET_POLICY run_id=\(expectedRunID ?? "none") origin=\(manualOrigin ?? "scheduled") mode=\(isCorrelatedManualRun ? "manual_all_apps" : "background_skip_running") requested_count=\(self.installedApps.count) attempted_count=\(filteredApps.count)")

            if !self.runningApplications.isEmpty {
                self.verboseLog("[BackgroundRefreshAppsOperation] Skipping refreshing running apps: \(self.runningApplications)")
            }

            let results = try await self.refresh(filteredApps)
            self.scheduleFinishedRefreshingNotification(for: .success(results), delay: 0)
            return results
        } catch {
            self.scheduleFinishedRefreshingNotification(for: .failure(error), delay: 0)
            throw error
        }
    }

    private func refresh(_ apps: [InstalledApp]) async throws -> [String: Result<InstalledApp, Error>] {
        return try await withCheckedThrowingContinuation { continuation in
            debugLog("[AUTO_REFRESH] SIGNING_STARTED app_count=\(apps.count)")
            let group = AppManager.shared.refresh(apps, presentingViewController: nil)
            self.refreshGroupLock.lock()
            self.activeRefreshGroup = group
            let shouldCancel = self.isCancelled
            self.refreshGroupLock.unlock()
            if shouldCancel { group.cancel() }

            group.beginInstallationHandler = { [weak self] (installedApp) in
                self?.debugLog("[AUTO_REFRESH] INSTALLATION_STARTED bundle_id=\(installedApp.bundleIdentifier)")
                if installedApp.bundleIdentifier == StoreApp.altstoreAppID {
                    self?.persistAutomaticHostHandoff()
                }
                guard let self = self else { return }
                guard installedApp.bundleIdentifier == StoreApp.altstoreAppID else { return }
                
                if let error = group.context.error {
                    self.scheduleFinishedRefreshingNotification(for: .failure(error))
                } else {
                    var results = group.results
                    results[installedApp.bundleIdentifier] = .success(installedApp)
                    self.scheduleFinishedRefreshingNotification(for: .success(results))
                }
            }
            group.completionHandler = { (results) in
                self.refreshGroupLock.lock()
                self.activeRefreshGroup = nil
                self.refreshGroupLock.unlock()
                self.persistAutomaticRefreshVerification(results: results,
                    attemptedAppIDs: apps.map { $0.bundleIdentifier })
                self.setProgress(100)
                continuation.resume(returning: results)
            }
        }
    }
    

    private func automaticRefreshDefaults() throws -> UserDefaults {
        // V3_RUNTIME_SHARED_REFRESH_STORE_V1: the one runtime App Group the host
        // published, resolved by the same V3SharedAppGroup identity IPA staging,
        // the secret handoff lock and the recovery journal use. It throws instead
        // of falling back to `.standard`, which would strand the host/service
        // contract: the host would never see the manifest this run writes.
        try V3SharedAppGroup.requireSharedUserDefaults()
    }

    private func persistAutomaticHostHandoff() {
        // The run already resolved the shared store before doing any work. A
        // store that becomes unavailable mid-run is an honest refusal: writing a
        // private record the host can never read would claim a handoff that did
        // not happen.
        guard let defaults = try? automaticRefreshDefaults() else {
            debugLog("[AUTO_REFRESH] HOST_HANDOFF_UNAVAILABLE reason=shared_store_unavailable")
            return
        }
        defaults.set(true, forKey: "liveContainerAutoRefreshHostHandoff")
        defaults.set(defaults.string(forKey: "liveContainerAutoRefreshExpectedRunID") ?? refreshIdentifier,
                     forKey: "liveContainerAutoRefreshHostHandoffRunID")
        defaults.set(Date(), forKey: "liveContainerAutoRefreshHostHandoffStartedAt")
        if let host = installedApps.first(where: { $0.bundleIdentifier == StoreApp.altstoreAppID }) {
            defaults.set(host.expirationDate, forKey: "liveContainerAutoRefreshHostPreviousExpiration")
        }
        debugLog("[AUTO_REFRESH] HOST_REFRESH_HANDOFF_STARTED run_id=\(refreshIdentifier)")
    }

    private func persistAutomaticRefreshVerification(results: [String: Result<InstalledApp, Error>],
                                                     attemptedAppIDs: [String]) {
        guard let defaults = try? automaticRefreshDefaults() else {
            debugLog("[AUTO_REFRESH] VERIFICATION_UNAVAILABLE reason=shared_store_unavailable")
            return
        }
        var serialized: [[String: Any]] = []
        for (bundleIdentifier, result) in results.sorted(by: { $0.key < $1.key }) {
            switch result {
            case .success(let app):
                debugLog("[AUTO_REFRESH] REFRESH_VERIFIED bundle_id=\(bundleIdentifier) refreshed_date=\(app.refreshedDate) expiration_date=\(app.expirationDate)")
                serialized.append(["bundle_id": bundleIdentifier, "name": app.name,
                    "success": true, "refreshed_date": app.refreshedDate,
                    "expiration_date": app.expirationDate])
            case .failure(let error):
                let runID = defaults.string(forKey: "liveContainerAutoRefreshExpectedRunID") ?? refreshIdentifier
                let failure = CombinedFailure.capture(V3HeadlessPairingFailure.tagIfInvalidPairing(error),
                    operation: "refresh", stage: .refreshVerification, id: runID)
                debugLog("[AUTO_REFRESH] REFRESH_FAILED \(failure.technicalDetails)")
                serialized.append(["bundle_id": bundleIdentifier, "success": false,
                    "error_code": failure.underlyingCode, "error_domain": failure.underlyingDomain,
                    "error": failure.message, "failure": failure.wire])
            }
        }
        // COMBINED_REFRESH_MANIFEST_V2: bind verification to the apps this engine actually attempted.
        let requestedIDs = installedApps.map { $0.bundleIdentifier }
        let requestedSet = Set(requestedIDs)
        let expectedIDs = attemptedAppIDs.filter { requestedSet.contains($0) }
        let expectedSet = Set(expectedIDs)
        let skippedIDs = requestedIDs.filter { !expectedSet.contains($0) }
        defaults.set(["version": 2, "date": Date(),
            "schema": "LiveContainerRefreshManifestV2",
            "expected_ids": expectedIDs, "requested_ids": requestedIDs, "skipped_ids": skippedIDs,
            "run_id": defaults.string(forKey: "liveContainerAutoRefreshExpectedRunID") ?? refreshIdentifier,
            "results": serialized,
            "host_handoff": defaults.bool(forKey: "liveContainerAutoRefreshHostHandoff")],
            forKey: "liveContainerAutoRefreshVerification")
        debugLog("[AUTO_REFRESH] VERIFICATION_MANIFEST_V1 run_id=\(refreshIdentifier) result_count=\(serialized.count)")
    }

    private func startListeningForRunningApps() {
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        
        for installedApp in self.installedApps {
            let appIsRunningNotification = CFNotificationName.appIsRunning(for: installedApp.bundleIdentifier)
            CFNotificationCenterAddObserver(notificationCenter, observer, ReceivedApplicationState, appIsRunningNotification.rawValue, nil, .deliverImmediately)
            
            let requestAppStateNotification = CFNotificationName.requestAppState(for: installedApp.bundleIdentifier)
            CFNotificationCenterPostNotification(notificationCenter, requestAppStateNotification, nil, nil, true)
        }
    }
    
    private func stopListeningForRunningApps() {
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        
        for installedApp in self.installedApps {
            let appIsRunningNotification = CFNotificationName.appIsRunning(for: installedApp.bundleIdentifier)
            CFNotificationCenterRemoveObserver(notificationCenter, observer, appIsRunningNotification, nil)
        }
    }
    
    fileprivate func receivedApplicationState(notification: CFNotificationName) {
        let baseName = String(CFNotificationName.appIsRunning.rawValue)
        
        let appID = String(notification.rawValue).replacingOccurrences(of: baseName + ".", with: "")
        self.runningApplications.insert(appID)
    }
    
    private func scheduleFinishedRefreshingNotification(for result: Result<[String: Result<InstalledApp, Error>], Error>, delay: TimeInterval = 5) {
        func scheduleFinishedRefreshingNotification() {
            #if !os(tvOS)
            self.cancelFinishedRefreshingNotification()
            
            let content = UNMutableNotificationContent()
            
            var shouldPresentAlert = true
            
            do {
                let results = try result.get()
                shouldPresentAlert = !results.isEmpty
                
                for (_, result) in results {
                    guard case let .failure(error) = result else { continue }
                    throw error
                }
                
                content.title = NSLocalizedString("Refreshed Apps", comment: "")
                content.body = NSLocalizedString("All apps have been refreshed.", comment: "")
            } catch OperationError.noConnection, OperationError.noVPN, OperationError.noInstalledApps {
                shouldPresentAlert = false
            } catch OperationError.serverNotFound where self.ignoresServerNotFoundError {
                shouldPresentAlert = false
            } catch {
                let runID = (try? automaticRefreshDefaults())?.string(forKey: "liveContainerAutoRefreshExpectedRunID") ?? refreshIdentifier
                let failure = CombinedFailure.capture(V3HeadlessPairingFailure.tagIfInvalidPairing(error),
                    operation: "refresh", stage: .refreshVerification, id: runID)
                self.debugLog("[AUTO_REFRESH] NOTIFICATION_FAILURE \(failure.technicalDetails)")


                
                content.title = NSLocalizedString("Failed to Refresh Apps", comment: "")
                content.body = failure.message
 
                shouldPresentAlert = true
            }

            if shouldPresentAlert {
                // Using nil if delay == 0 fixes race condition where multiple notifications can appear (or none).
                let trigger = delay == 0 ? nil : UNTimeIntervalNotificationTrigger(timeInterval: delay + 1, repeats: false)
                
                let request = UNNotificationRequest(identifier: self.refreshIdentifier, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(request)
                
                if delay > 0 {
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
                        // If app is still running at this point, we schedule another notification with same identifier.
                        // This prevents the currently scheduled notification from displaying, and starts another countdown timer.
                        // First though, make sure there _is_ still a pending request, otherwise it's been cancelled
                        // and we should stop polling.
                        guard requests.contains(where: { $0.identifier == self.refreshIdentifier }) else { return }
                        
                        scheduleFinishedRefreshingNotification()
                    }
                }
            }
            #else
            NotificationCenter.default.post(name: NSNotification.Name("TVTopShelfItemsDidChangeNotification"), object: nil)
            #endif
        }
        
        if self.presentsFinishedNotification {
            scheduleFinishedRefreshingNotification()
        }        
        
        // Perform synchronously to ensure app doesn't quit before we've finishing saving to disk.
        let dbContext = self.context.dbBackgroundContext
        let childContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        childContext.parent = dbContext
        childContext.performAndWait {
            self.saveRefreshAttempt(result: result, in: childContext)
        }
        dbContext.performAndWait {
            do { try dbContext.save() }
            catch { debugLog("Failed to save parent context for refresh attempt. \(error.localizedDescription)") }
        }
    }
    
    private func saveRefreshAttempt(result: Result<[String: Result<InstalledApp, Error>], Error>, in context: NSManagedObjectContext) {
        _ = RefreshAttempt(identifier: self.refreshIdentifier, result: result, context: context)
        
        do { try context.save() }
        catch { debugLog("Failed to save refresh attempt. \(error.localizedDescription)") }
    }
    
    private func cancelFinishedRefreshingNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [self.refreshIdentifier])
    }
}
