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
                                completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup
    {
        let group = RefreshGroup(context: context)
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
        let operations = operations.filter { progress.progress(for: $0) == nil || progress.progress(for: $0)?.isCancelled == true }
        guard !operations.isEmpty else { throw OperationError.cancelled }
        
        let backgroundTaskID = await MainActor.run {
            var taskID = UIBackgroundTaskIdentifier.invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "com.altstore.AppManager.perform") {
                UIApplication.shared.endBackgroundTask(taskID)
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
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
        
        // COMBINED_COREDEVICE_PIPELINE_BATCH_V1: lease before readiness, release on every returning path.
        let transportCore = minimuxer.core
        await transportCore.beginTransportBatch()
        do {
        /* Minimuxer Readiness Check */
        if !CellularRefreshManager.shared.isEnabled,
           case .failure(let error) = await isMinimuxerReady()
        {
            let opError = V3RefreshEarlyFailureBoundary.readiness.preserving(
                V3HeadlessPairingFailure.tagIfInvalidPairing(error.asOperationError), operations: operations)
            group.context.error = opError
            for operation in operations {
                let elapsed = CFAbsoluteTimeGetCurrent() - group.operationStartTime
                operation.logSummary(status: "FAILED", elapsed: elapsed, error: opError)
            }
            throw opError
        }
        
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
                    try await self.performOperation(for: operation, handler: handler, group: group, operationsCount: operationsCount)
                }
            }
            while let _ = try await taskGroup.next() {}
        }
        for operation in hostOperations {
            try Task.checkCancellation()
            try await self.performOperation(for: operation, handler: handler, group: group, operationsCount: operationsCount)
        }
        // Outer entry wrappers publish completion after their final admission checks.
        await transportCore.endTransportBatch()
        return group
        } catch {
            await transportCore.endTransportBatch()
            throw error
        }
    }

    func performOperation(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup, operationsCount: Int = 1) async throws {
        debugLog("[AppManager] performOperation: Starting execution for app: \(operation.bundleIdentifier)")
        defer {
            // request update view context's in-mem coredata caches (coz we worked so far on bg context)
            Task { @MainActor in
                DatabaseManager.shared.viewContext.processPendingChanges()
            }
        }
        do {
            let result = try await self.performPipeline(for: operation, handler: handler, group: group, operationsCount: operationsCount)
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
    
    private func performPipeline(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup, operationsCount: Int = 1) async throws -> InstalledApp
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
        
        if let app = operation.app as? InstalledApp {
            context.installedApp = app
            context.appBundleFingerprint = app.appBundleFingerprint
            context.useMainProfile = app.useMainProfile
            context.customBundleIdentifier = app.customBundleIdentifier
            context.targetAppBundle = ALTApplication(fileURL: app.fileURL)
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
        return try await PipelineExecutor.shared.executePipeline(
            steps: pipelineSteps,
            context: context,
            operation: operation,
            group: group,
            downloadingApp: downloadingApp,
            permissionsMode: permissionsMode,
            operationProgress: operationProgress
        )
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
