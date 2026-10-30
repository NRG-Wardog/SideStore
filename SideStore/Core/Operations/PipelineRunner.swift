//
//  PipelineRunner.swift
//  AltStore
//
//  Created by Magesh K on 8/3/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import CoreData
import SideSign
import Minimuxer


// Memory-only comparison. Never serialized: peer addresses remain private.
// No public backend configuration generation exists; this compares observations
// before/after the native await, not uninterrupted configuration equivalence.
private struct V3TransportObservationConfiguration: Equatable {
    let core: ObjectIdentifier
    let gateway: ObjectIdentifier
    let startupGeneration: UUID
    let localVPN: Bool
    let peerOverride: String
    let remoteServer: String
    let remotePort: UInt16
    let coreDeviceEnabled: Bool
    let cellularEnabled: Bool

    static func capture() -> Self {
        let facade = minimuxer
        let gateway = facade.gateway
        let config = ConnectionConfig.shared
        return Self(core: ObjectIdentifier(facade.core), gateway: ObjectIdentifier(gateway),
                    startupGeneration: V3PairingTransportReceipt.shared.observationGeneration(),
                    localVPN: config.useLocalVPN, peerOverride: config.overrideTunnelPeerIp,
                    remoteServer: config.remoteServerIp, remotePort: gateway.getPort(for: .rppairing),
                    coreDeviceEnabled: gateway.coreDeviceTransportEnabled,
                    cellularEnabled: CellularRefreshManager.shared.isEnabled)
    }
}

// V3_OWNED_REFRESH_READINESS_WAIT_V1: observations only, before app mutation.
// The budget bounds starting/repeating probes, not preemption of an in-flight
// network probe. Native device initialization runs once, outside this grace budget.
final class V3RefreshReadinessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var ended = false
    func expire() { lock.withLock { expired = true } }
    func check() throws {
        if lock.withLock({ expired }) { throw OperationError.timedOut }
    }
    func claimEnd() -> Bool {
        lock.withLock {
            guard !ended else { return false }
            ended = true
            return true
        }
    }
}

enum V3OwnedRefreshReadinessWait {
    static let budget: TimeInterval = 10
    static let maximumProbes = 12
    static func run(probe: () async -> MinimuxerOwnedReadinessObservation,
                    checkOwnership: () throws -> Void,
                    diagnostic: (Int, TimeInterval, String, String) -> Void = { _, _, _, _ in },
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws {
        let started = now()
        guard started.isFinite, started >= 0 else { throw OperationError.timedOut }
        func elapsed() throws -> TimeInterval {
            let value = now() - started
            guard value.isFinite, value >= 0 else { throw OperationError.timedOut }
            return value
        }
        var count = 0
        while true {
            try Task.checkCancellation()
            try checkOwnership()
            let beforeProbe = try elapsed()
            guard count < maximumProbes, beforeProbe < budget else {
                diagnostic(count, min(beforeProbe, budget), "none", "deadline")
                throw OperationError.timedOut
            }
            count += 1
            let observation = await probe()
            try Task.checkCancellation()
            try checkOwnership()
            let afterProbe = try elapsed()
            guard afterProbe < budget else {
                diagnostic(count, min(afterProbe, budget), "none", "lateProbe")
                throw OperationError.timedOut
            }
            switch observation.result {
            case .success(true):
                diagnostic(count, afterProbe, "none", "ready")
                return
            case .success(false):
                // UI-only observations are never owned network readiness proof.
                throw OperationError.minimuxerNotStarted(reason: "The owned transport probe did not confirm network readiness.")
            case .failure(let error):
                guard let reason = observation.transient else {
                    diagnostic(count, afterProbe, "none", "terminal")
                    throw error
                }
                diagnostic(count, afterProbe, reason.rawValue, "pending")
                // A final sleep cannot produce another observation. Preserve this
                // fresh, owned negative instead of replacing it with a timeout:
                // the host requires its typed pre-mutation evidence to activate VPN.
                // Never retain a negative across sleep or accept a late probe.
                let schedulingElapsed = try elapsed()
                guard schedulingElapsed < budget else { throw OperationError.timedOut }
                let delay: TimeInterval = count == 1 ? 0.2 : count == 2 ? 0.4 : count == 3 ? 0.8 : 1.0
                if count >= maximumProbes || delay >= budget - schedulingElapsed {
                    try Task.checkCancellation()
                    try checkOwnership()
                    diagnostic(count, schedulingElapsed, reason.rawValue, "graceExhausted")
                    throw error
                }
                try await sleep(UInt64(delay * 1_000_000_000))
            }
        }
    }
}
// V3_OWNED_REFRESH_READINESS_WAIT_END

protocol PipelineProgress: Sendable{
    func progress(for operation: AppOperation) -> Progress?
    func set(_ progress: Progress?, for operation: AppOperation)
}
protocol PipelineExecutionContext: AnyObject, Sendable {
    var isActivelyManagingAnyApp: Bool { get }
}
protocol PipelineErrorLogger: AnyObject, Sendable {
    func log(_ error: Error, operation: LoggedError.Operation, app: AppProtocol)
    func getMappedError(for operation: AppOperation, error: Error) -> Error
}


// Pipeline based App Operations
final class PipelineRunner: Sendable
{
    let progress: PipelineProgress
    let context: PipelineExecutionContext
    let logger: PipelineErrorLogger
    let defaultEntitlements: [ALTEntitlement: any Sendable]
    
    init(progress: PipelineProgress,
         context: PipelineExecutionContext,
         logger: PipelineErrorLogger,
         defaultEntitlements: [ALTEntitlement: any Sendable] = [:])
    {
        self.progress = progress
        self.context = context
        self.logger = logger
        self.defaultEntitlements = defaultEntitlements
    }
    
    @discardableResult
    func performSingleOperation(_ operation: AppOperation,
                                handler: PipelineExecutionHandler,
                                dbContext: NSManagedObjectContext,
                                completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup
    {
        // Retain the upstream database-only entry point and its fresh context.
        let context = StandaloneOperationContext(steps: [], dbBackgroundContext: dbContext)
        return self.performSingleOperation(operation, handler: handler, context: context,
                                           completionHandler: completionHandler)
    }

    // V3_PIPELINE_CONTEXT_BRIDGE_V1: host operations retain their shared progress/error context.
    @discardableResult
    func performSingleOperation(_ operation: AppOperation,
                                handler: PipelineExecutionHandler,
                                context: StandaloneOperationContext,
                                suppliedGroup: RefreshGroup? = nil,
                                completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup
    {
        let group = suppliedGroup ?? RefreshGroup(context: context)
        guard group.context === context, group.activeTask == nil, group.results.isEmpty else {
            completionHandler(.failure(OperationError.invalidOperationContext("The supplied operation group is not a fresh matching owner.")))
            return group
        }
        group.completionHandler = { (results) in
            do
            {
                guard let result = results.values.first else {
                    throw group.error ?? OperationError.unknownResult
                }
                let installedApp = try result.get()
                completionHandler(.success(installedApp))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        debugLog("[AppManager] performSingleOperation started for: \(operation.bundleIdentifier)")
        let queuedAdmission: V3RemoteRequestAdmission
        do { queuedAdmission = try V3RemoteRequestLeases.capture() }
        catch { completionHandler(.failure(error)); return group }
        group.activeTask = Task.detached {
            defer { queuedAdmission.close() }
            do {
                debugLog("[AppManager] performSingleOperation executing task for: \(operation.bundleIdentifier)")
                try await queuedAdmission.withScope {
                    try await self.perform([operation], handler: handler, group: group)
                }
                try await MainActor.run {
                    try queuedAdmission.check()
                    queuedAdmission.close()
                    // Publish once, after all scope checks, on the original callback actor.
                    group.completionHandler?(group.results)
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    debugLog("[AppManager] performSingleOperation task cancelled.")
                    completionHandler(.failure(OperationError.cancelled))
                    return
                }
                debugLog("[AppManager] performSingleOperation task failed for: \(operation.bundleIdentifier) with error: \(error)")
                completionHandler(.failure(error))
            }
        }
        
        return group
    }
    
    func performVoidOperation(_ operation: AppOperation,
                              handler: PipelineExecutionHandler,
                              dbContext: NSManagedObjectContext,
                              completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        self.performSingleOperation(operation, handler: handler, dbContext: dbContext) { (result) in
            switch result {
            case .success:
                completionHandler(.success(()))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }
    
    @discardableResult
    func perform(_ operations: [AppOperation],
                 handler: PipelineExecutionHandler,
                 group: RefreshGroup) async throws -> RefreshGroup
    {
        try await V3RemoteRequestLeases.withAuthorizedRoute {
            try await self.performUsingAdmittedRoute(operations, handler: handler, group: group)
        }
    }

    private func performUsingAdmittedRoute(_ operations: [AppOperation],
                 handler: PipelineExecutionHandler,
                 group: RefreshGroup) async throws -> RefreshGroup
    {
        for operation in operations where group.verification(for: operation.bundleIdentifier) == nil {
            group.setVerification(V3RefreshVerification(installAcknowledged: false, mutationDispatched: false),
                                  for: operation.bundleIdentifier)
        }
        let operations = operations.filter { progress.progress(for: $0) == nil || progress.progress(for: $0)?.isCancelled == true }
        guard !operations.isEmpty else { throw OperationError.cancelled }
        
        let readinessLifetime = V3RefreshReadinessLifetime()
        let backgroundTaskID = await MainActor.run {
            var taskID = UIBackgroundTaskIdentifier.invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "com.altstore.AppManager.perform") {
                readinessLifetime.expire()
                if readinessLifetime.claimEnd() { UIApplication.shared.endBackgroundTask(taskID) }
            }
            return taskID
        }
        
        // Disable the idleTimeout
        await MainActor.run {
            if !UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.isIdleTimeoutDisableEnabled
            }
        }
        
        defer {
            for operation in operations {                   // Clean up progress for all operations
                progress.set(nil, for: operation)
            }
            if let error = group.error {            // Mark error as-is
                for operation in operations {
                    group.set(.failure(error), forAppWithBundleIdentifier: operation.bundleIdentifier)
                }
            }
            
            
            // Re-enable idleTimeout if no more actions are running and end background task
            Task { @MainActor in
                if UIApplication.shared.isIdleTimerDisabled && !context.isActivelyManagingAnyApp {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                if backgroundTaskID != .invalid, readinessLifetime.claimEnd() {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
        
        // COMBINED_COREDEVICE_PIPELINE_BATCH_V1: lease before readiness, release on every returning path.
        let transportCore = minimuxer.core
        let transportCoreIdentity = ObjectIdentifier(transportCore)
        await transportCore.beginTransportBatch()
        do {
        /* Minimuxer Readiness Check */
        func checkReadinessOwnership() throws {
            try Task.checkCancellation()
            try V3RemoteRequestLeases.admitted?.check()
            try readinessLifetime.check()
            guard ObjectIdentifier(minimuxer.core) == transportCoreIdentity else {
                throw OperationError.invalidOperationContext("The owned readiness transport changed.")
            }
        }
        do {
            try checkReadinessOwnership()
            if !CellularRefreshManager.shared.isEnabled {
                let transportObservationConfiguration = V3TransportObservationConfiguration.capture()
                let initialMode = await transportCore.getConnectionMode()
                try checkReadinessOwnership()
                if initialMode == .localVPN {
                    try await V3OwnedRefreshReadinessWait.run(probe: {
                        guard await transportCore.getConnectionMode() == initialMode else {
                            return .init(result: .success(false), transient: nil)
                        }
                        let observation = await transportCore.ownedNetworkReadinessProbe(withNetworkCheck: true)
                        guard await transportCore.getConnectionMode() == initialMode else {
                            return .init(result: .success(false), transient: nil)
                        }
                        return observation
                    }, checkOwnership: checkReadinessOwnership, diagnostic: { count, elapsed, reason, outcome in
                        debugLog("[V3_OWNED_READINESS] attempt=\(count) elapsed=\(Int(elapsed * 1000))ms reason=\(reason) outcome=\(outcome)")
                    })
                    // Network readiness is not device readiness. The original native
                    // initialization runs exactly once, without the network grace deadline.
                    try checkReadinessOwnership()
                    let nativeResult = await transportCore.isReady(
                        withNetworkCheck: true, withDDIMountCheck: false)
                    try checkReadinessOwnership()
                    switch nativeResult {
                    case .success(true):
                        try group.recordTransportReady(nativeReady: true,
                            configurationUnchanged: transportObservationConfiguration == .capture(),
                            checkOwnership: checkReadinessOwnership)
                    case .success(false): throw OperationError.minimuxerNotStarted(reason: "Device readiness was not confirmed.")
                    case .failure(let error): throw error
                    }
                } else {
                    // Remote and unconfigured routes retain their original
                    // one-shot behavior, without a new local-VPN grace deadline.
                    let nativeResult = await transportCore.isReady(
                        withNetworkCheck: true, withDDIMountCheck: false)
                    if case .failure(let error) = nativeResult { throw error }
                    if case .success(true) = nativeResult {
                        try group.recordTransportReady(nativeReady: true,
                            configurationUnchanged: transportObservationConfiguration == .capture(),
                            checkOwnership: checkReadinessOwnership)
                    }
                }
            }
            try checkReadinessOwnership()
        } catch {
            if error is CancellationError { throw error }
            let typedError: Error
            if let native = error as? MinimuxerError { typedError = native.asOperationError }
            else { typedError = error }
            let opError = V3RefreshEarlyFailureBoundary.readiness.preserving(
                V3HeadlessPairingFailure.tagIfInvalidPairing(typedError), operations: operations)
            group.context.error = opError
            for operation in operations {
                let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
                operation.logSummary(status: "FAILED", elapsed: elapsed, error: opError)
            }
            throw opError
        }
        
        try checkReadinessOwnership()
        group.progress.totalUnitCount = Int64(operations.count * 100)
        // V3_PROGRESS_BASELINE_FIX_V1: child weights already span the full total.
        group.progress.completedUnitCount = 0
        
        for operation in operations
        {
            let progress = Progress.discreteProgress(totalUnitCount: 100)
            self.progress.set(progress, for: operation)
            group.progress.addChild(progress, withPendingUnitCount: 100)
        }
        
        
        /* Preflight SideStore specific validations */
        let unhandledOperations = operations.filter { operation in
            let isSideStore = (operation.app as? ALTApplication)?.isAltStoreApp == true ||
                               operation.bundleIdentifier.isAltStoreAppID
            
            if isSideStore {
                return handler.preflightChecksHandler.isResignActive == true
            }
            return true
        }
        
        do {
            let preflightContext = StandaloneOperationContext(steps: .preflightChecks, dbBackgroundContext: group.dbContext)
            let validateOp = try PreflightChecksOperation(
                operations: unhandledOperations,
                handler: handler.preflightChecksHandler,
                context: preflightContext
            )
            try await validateOp.execute()
        } catch {
            let error = V3RefreshEarlyFailureBoundary.preflight.preserving(error, operations: operations)
            group.error = error
            for operation in operations {
                let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
                operation.logSummary(status: "FAILED", elapsed: elapsed, error: error)
            }
            throw error
        }
        
        
        // Deferred cellular injection can publish success before device mutation.
        // Keep per-app injection until it shares the durable outcome contract.
        let operationsCount = operations.count
        group.isCellularRefreshGroup = false

        // Finish standalone apps before a host replacement can terminate us.
        let hostOperations = operations.filter {
            ($0.app as? ALTApplication)?.isAltStoreApp == true || $0.bundleIdentifier.isAltStoreAppID
        }
        let normalOperations = operations.filter {
            !(($0.app as? ALTApplication)?.isAltStoreApp == true || $0.bundleIdentifier.isAltStoreAppID)
        }
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for operation in normalOperations {
                taskGroup.addTask {
                    try Task.checkCancellation()
                    try V3RemoteRequestLeases.admitted?.check()
                    try readinessLifetime.check()
                    guard ObjectIdentifier(minimuxer.core) == transportCoreIdentity else {
                        throw OperationError.invalidOperationContext("The owned readiness transport changed.")
                    }
                    try await self.performOperation(for: operation, handler: handler, group: group, operationsCount: operationsCount, refreshAdmission: checkReadinessOwnership, readProfiles: {
                        try checkReadinessOwnership()
                        let result = try await transportCore.readInstalledProvisioningProfiles()
                        try checkReadinessOwnership()
                        return result
                    })
                }
            }
            while let _ = try await taskGroup.next() {}
        }
        for operation in hostOperations {
            try checkReadinessOwnership()
            try await self.performOperation(for: operation, handler: handler, group: group, operationsCount: operationsCount, refreshAdmission: checkReadinessOwnership, readProfiles: {
                        try checkReadinessOwnership()
                        let result = try await transportCore.readInstalledProvisioningProfiles()
                        try checkReadinessOwnership()
                        return result
                    })
        }
        // Outer entry wrappers publish completion after their final admission checks.
        await transportCore.endTransportBatch()
        return group
        } catch {
            await transportCore.endTransportBatch()
            throw error
        }
    }

    func performOperation(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup, operationsCount: Int = 1, refreshAdmission: (() throws -> Void)? = nil, readProfiles: (() async throws -> [Data])? = nil) async throws {
        debugLog("[AppManager] performOperation: Starting execution for app: \(operation.bundleIdentifier)")
        defer {
            // request update view context's in-mem coredata caches (coz we worked so far on bg context)
            Task { @MainActor in
                DatabaseManager.shared.viewContext.processPendingChanges()
            }
        }
        do {
            group.setVerification(V3RefreshVerification(installAcknowledged: false, mutationDispatched: false),
                                  for: operation.bundleIdentifier)
            let result = try await self.performPipeline(for: operation, handler: handler, group: group, operationsCount: operationsCount, refreshAdmission: refreshAdmission, readProfiles: readProfiles)
            if operationsCount <= 1 {
                progress.set(nil, for: operation)
                debugLog("[AppManager] performOperation: completed successfully; progress was reset.")
            }
            
            // persist the result
            let bundleID = result.bundleIdentifier
            let dbContext = group.context.dbBackgroundContext
            // V3_POST_MUTATION_PERSISTENCE_CONTRACT_V1: the device mutation may
            // already have happened. A failed durable commit is a non-retryable
            // persistence outcome, never operation success. Do not log native error text.
            try await dbContext.perform {
                let hasChanges = dbContext.hasChanges
                try V3MutationPersistencePolicy.persistResult(hasChanges: hasChanges) {
                    try dbContext.save()
                }
                debugLog("[AppManager] performOperation: InstalledApp result persistence confirmed for \(bundleID)")
            }
            
            group.set(.success(result), forAppWithBundleIdentifier: bundleID)
            debugLog("[AppManager] performOperation: Execution SUCCESS for app: \(operation.bundleIdentifier)")
            
            let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
            operation.logSummary(status: "SUCCESS", elapsed: elapsed)
            
            debugLog("[AppManager] performOperation: Reloading widget timelines...")
            await WidgetDataManager.publishCurrentInstalledApps(in: dbContext)
            debugLog("[AppManager] performOperation: Reloading COMPLETE for widget timelines.")
            
            if result.bundleIdentifier == StoreApp.altstoreAppID {
                let context = StandaloneOperationContext(steps: .scheduleExpirationWarningNotification, dbBackgroundContext: group.dbContext)
                let scheduleNotifOp = try ScheduleExpirationWarningNotificationOperation(
                    installedApp: result,
                    context: context
                )
                try await scheduleNotifOp.execute()
            }
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
        } catch {
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
            progress.set(nil, for: operation)
            
            let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
            let isCancelled = Task.isCancelled || error is CancellationError
            let status = isCancelled ? "CANCELLED" : "FAILED"
            if isCancelled {
                debugLog("[AppManager] performOperation: Execution CANCELLED for app: \(operation.bundleIdentifier)")
            } else {
                debugLog("[AppManager] performOperation: Execution FAILED for app: \(operation.bundleIdentifier) with error: \(error.localizedDescription)")
            }
            operation.logSummary(status: status, elapsed: elapsed, error: error)
            
            if isCancelled {
                // Cancellation error is logged and ignored
                group.set(.failure(OperationError.cancelled), forAppWithBundleIdentifier: operation.bundleIdentifier)
                return
            }
            
            let mappedError = logger.getMappedError(for: operation, error: error)
            
            logger.log(error, operation: operation.loggedErrorOperation, app: operation.app)
            
            group.set(.failure(mappedError), forAppWithBundleIdentifier: operation.bundleIdentifier)
        }
    }
    
    private func performPipeline(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup, operationsCount: Int = 1, refreshAdmission: (() throws -> Void)? = nil, readProfiles: (() async throws -> [Data])? = nil) async throws -> InstalledApp
    {
        let pipelineSteps = PipelineStepDefinition.steps(for: operation)
        let context = InstallAppOperationContext(
            pipelineSteps: pipelineSteps,
            bundleIdentifier: operation.bundleIdentifier,
            dbBackgroundContext: group.dbContext,
            sharedContext: group.sharedContext,
            handler: handler,
            additionalEntitlements: defaultEntitlements,
            activeSigningCertificate: CertificateManager.shared.activeCertificate?.certificate
        )
        context.recordRefreshVerification = { group.setVerification($0, for: operation.bundleIdentifier) }
        context.profileMutationAdmission = refreshAdmission
        context.readInstalledProvisioningProfiles = readProfiles
        context.isCellularRefreshGroup = group.isCellularRefreshGroup
        context.groupOperationsCount = operationsCount
        
        switch operation {
            case .install(_, let customID), .reinstall(_, let customID):
                context.customBundleIdentifier = customID
            case .update(_, let customID):
                context.customBundleIdentifier = customID
                context.isStoreUpdate = true
            case .resign(_, let mode):
                context.alternateIconMode = mode
            default:
                break
        }
        
        // The prepared copy belongs only to this operation and outlives every
        // awaited pipeline step. Cleanup never removes shared caches or the host.
        var preparedHostRefreshBundle: V3HostRefreshBundlePreparation.Prepared?
        defer { preparedHostRefreshBundle?.removeOwnedCopy() }
        if let app = operation.app as? InstalledApp {
            context.installedApp = app
            context.appBundleFingerprint = app.appBundleFingerprint
            context.useMainProfile = app.useMainProfile
            context.customBundleIdentifier = app.customBundleIdentifier
            context.targetAppBundle = ALTApplication(fileURL: app.fileURL)
            // V3_HOST_REFRESH_BUNDLE_PREPARATION_V1: no download occurs in a
            // refresh pipeline. Recover missing self metadata from the exact
            // installed host, without changing payload-cache or signing policy.
            if case .refresh = operation, context.targetAppBundle == nil,
               app.bundleIdentifier == StoreApp.altstoreAppID {
                do {
                    let prepared = try V3HostRefreshBundlePreparation.prepare(
                        originalBundleID: app.bundleIdentifier,
                        resignedBundleID: app.resignedBundleIdentifier,
                        expectedOriginalBundleID: StoreApp.altstoreAppID,
                        activeBundleID: Bundle.Info.activeBundleIdentifier,
                        activeBundleURL: Bundle.Info.activeBundleURL,
                        extensions: app.appExtensions.map {
                            .init(original: $0.bundleIdentifier, resigned: $0.resignedBundleIdentifier)
                        }, checkAdmission: {
                            try Task.checkCancellation()
                            try V3RemoteRequestLeases.admitted?.check()
                        })
                    preparedHostRefreshBundle = prepared
                    context.targetAppBundle = prepared.appBundle
                } catch {
                    if error is CancellationError { throw error }
                    throw lcStructuredSigningFailure(error, stage: "command", sourceStep: nil,
                                                     facts: lcRefreshFailureFacts(error))
                }
            }
            context.validatedReuseMain = app.useMainProfile && V3ValidatedReuseMainRegistry.contains(
                original: app.bundleIdentifier, resigned: app.resignedBundleIdentifier,
                profileUUID: context.targetAppBundle?.provisioningProfile?.uuid,
                generation: context.targetAppBundle?.infoPlist[V3ValidatedReuseMainRegistry.generationKey] as? String)
            if app.useMainProfile && !context.validatedReuseMain &&
                V3ValidatedReuseMainRegistry.hasAssociation(original: app.bundleIdentifier, resigned: app.resignedBundleIdentifier) {
                throw OperationError.invalidParameters("The cached app no longer matches its validated ReuseMain installation. Reinstall interactively instead of silently switching signing strategies.")
            }
        }
        
        context.beginInstallationHandler = { (installedApp) in
            group.beginInstallationHandler?(installedApp)
        }
        
        var downloadingApp = operation.app
        if let installedApp = operation.app as? InstalledApp {
            if case .resign = operation { downloadingApp = installedApp }
            else if let storeApp = installedApp.storeApp, !FileManager.default.fileExists(atPath: installedApp.fileURL.path) {
                downloadingApp = storeApp
            }
        }
        
        let permissionReviewMode: PermissionReviewMode
        switch operation {
            case .install, .reinstall: permissionReviewMode = .all
            case .update: permissionReviewMode = .added
            default: permissionReviewMode = .none
        }
        
        let permissionsMode = UserDefaults.standard.permissionCheckingDisabled ? .none : permissionReviewMode
        let operationProgress = progress.progress(for: operation)
        let completedApp = try await PipelineExecutor.shared.executePipeline(
            steps: pipelineSteps,
            context: context,
            operation: operation,
            group: group,
            downloadingApp: downloadingApp,
            permissionsMode: permissionsMode,
            operationProgress: operationProgress,
            refreshAdmission: refreshAdmission
        )
        if let verification = context.refreshVerification {
            group.setVerification(verification, for: completedApp.bundleIdentifier)
        }
        return completedApp
    }
}




// V3_REFRESH_EARLY_FAILURE_BOUNDARIES_V1: these checks precede executeStep,
// so preserve their finite responsibility before AppManager forms app results.
// This is diagnostic evidence only; the existing check and throw remain intact.
enum V3RefreshEarlyFailureBoundary {
    case readiness, preflight

    func preserving(_ error: Error, operations: [AppOperation]) -> Error {
        guard !operations.isEmpty, operations.allSatisfy({
            if case .refresh = $0 { return true }; return false
        }) else { return error }
        if error is CancellationError || error is CombinedFailure { return error }
        let native = error as NSError
        if CombinedFailure.isURLCancellation(domain: native.domain, code: native.code) { return error }
        let step: CombinedFailure.SourceStep = self == .readiness ? .refreshReadiness : .refreshPreflight
        let stage: CombinedFailure.Stage
        if let operation = error as? OperationError, case .notAuthenticated = operation {
            stage = .authentication
        } else {
            // A readiness failure is not, by itself, proof of networking,
            // pairing, signing, or installation failure.
            stage = .command
        }
        return lcStructuredSigningFailure(error, stage: stage.rawValue,
            sourceStep: step.rawValue, facts: lcRefreshFailureFacts(error, sourceStep: step.rawValue))
    }
}

// V3_HOST_REFRESH_BUNDLE_PREPARATION_BEGIN
// The self-app's installable payload cache is optional. A profile-only refresh
// still needs the exact running host's metadata, never a catalog replacement.
// Use a request-owned canonical copy, not a global fileURL fallback: no signing
// or staging operation may accidentally write into the installed application.
enum V3HostRefreshBundlePreparation {
    struct ExtensionIdentity {
        let original: String
        let resigned: String
    }

    struct Prepared {
        let appBundle: ALTApplication
        let ownedDirectory: URL

        func removeOwnedCopy() {
            try? FileManager.default.removeItem(at: ownedDirectory)
        }
    }

    static func prepare(originalBundleID: String, resignedBundleID: String,
                        expectedOriginalBundleID: String, activeBundleID: String,
                        activeBundleURL: URL, extensions: [ExtensionIdentity],
                        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                        checkAdmission: () throws -> Void) throws -> Prepared {
        try checkAdmission()
        guard !originalBundleID.isEmpty, originalBundleID == expectedOriginalBundleID,
              !resignedBundleID.isEmpty, resignedBundleID == activeBundleID,
              let source = ALTApplication(fileURL: activeBundleURL),
              source.bundleIdentifier == resignedBundleID,
              source.provisioningProfile != nil else {
            throw OperationError.invalidApp(reason: "The running host does not match the self-refresh target.")
        }
        var originalByResigned: [String: String] = [:]
        var originalIDs = Set<String>()
        for identity in extensions {
            guard identity.original.hasPrefix(originalBundleID + "."),
                  identity.resigned.hasPrefix(resignedBundleID + "."),
                  identity.original.dropFirst(originalBundleID.count) == identity.resigned.dropFirst(resignedBundleID.count),
                  originalByResigned[identity.resigned] == nil,
                  originalIDs.insert(identity.original).inserted else {
                throw OperationError.invalidApp(reason: "The self-refresh extension identities are inconsistent.")
            }
            originalByResigned[identity.resigned] = identity.original
        }
        let sourceExtensionIDs = source.appExtensions.map { $0.bundleIdentifier }
        guard Set(sourceExtensionIDs).count == sourceExtensionIDs.count,
              Set(sourceExtensionIDs) == Set(originalByResigned.keys) else {
            throw OperationError.invalidApp(reason: "The running host extensions do not match the self-refresh target.")
        }
        // Keep the preservation-mode verifier intact. Unsupported entries and
        // unreadable files must fail before copy, not be omitted or followed.
        guard let sourceFingerprint = AppBundleFingerprint.compute(for: activeBundleURL) else {
            throw OperationError.invalidApp(reason: "The running host payload could not be verified for refresh.")
        }
        try checkAdmission()
        let owner = temporaryDirectory.appendingPathComponent("v3-host-refresh-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: owner) } }
        let copyURL = owner.appendingPathComponent("App.app", isDirectory: true)
        try FileManager.default.copyItem(at: activeBundleURL, to: copyURL)
        try checkAdmission()
        guard AppBundleFingerprint.compute(for: copyURL) == sourceFingerprint,
              AppBundleFingerprint.compute(for: activeBundleURL) == sourceFingerprint,
              let copy = ALTApplication(fileURL: copyURL),
              copy.bundleIdentifier == resignedBundleID else {
            throw OperationError.invalidApp(reason: "The running host changed or its refresh copy did not verify.")
        }
        // Match DatabaseManager's canonical-cache identifiers. Signed Mach-O
        // entitlements, embedded profiles, all other files and the live host
        // stay untouched. The effective/custom ID remains in the context.
        try copy.updateInfoPlist(with: ["CFBundleIdentifier": originalBundleID])
        for appExtension in copy.appExtensions {
            guard let original = originalByResigned[appExtension.bundleIdentifier] else {
                throw OperationError.invalidApp(reason: "The refresh copy contains an unexpected extension.")
            }
            try appExtension.updateInfoPlist(with: ["CFBundleIdentifier": original])
        }
        try checkAdmission()
        guard AppBundleFingerprint.compute(for: activeBundleURL) == sourceFingerprint,
              AppBundleFingerprint.compute(for: copyURL) != nil,
              let prepared = ALTApplication(fileURL: copyURL),
              prepared.bundleIdentifier == originalBundleID,
              prepared.provisioningProfile != nil,
              Set(prepared.appExtensions.map { $0.bundleIdentifier }) == originalIDs,
              prepared.appExtensions.count == extensions.count else {
            throw OperationError.invalidApp(reason: "The canonical self-refresh bundle could not be verified.")
        }
        try checkAdmission()
        published = true
        return Prepared(appBundle: prepared, ownedDirectory: owner)
    }
}
// V3_HOST_REFRESH_BUNDLE_PREPARATION_END
