//
//  RefreshAllAppsIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents

// Shouldn't conform types we don't own to protocols we don't own, so make custom
// NSError subclass that conforms to CustomLocalizedStringResourceConvertible instead.
//
// Would prefer to just conform ALTLocalizedError to CustomLocalizedStringResourceConvertible,
// but that can't be done without raising minimum version for ALTLocalizedError to iOS 16 :/
@available(iOS 16, tvOS 16, *)
class IntentError: NSError, CustomLocalizedStringResourceConvertible, @unchecked Sendable
{
    var localizedStringResource: LocalizedStringResource {
        return "\(self.localizedDescription)"
    }
    
    init(_ error: some Error)
    {
        // V3_INTENT_ERROR_PRIVACY_V1: Shortcuts/Siri receive only safe structured identity and fixed copy.
        let serializedError = V3PersistedErrorSanitizer.sanitize(error as NSError)
        super.init(domain: serializedError.domain, code: serializedError.code, userInfo: serializedError.userInfo)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
}

// V3_HEADLESS_INSTALL_IPA_INTENT_REMOVED_V1: IPA installation is host-owned.

@available(iOS 17.0, tvOS 17.0, *)
extension RefreshAllAppsIntent
{
    // V3_SHORTCUT_GUEST_BACKEND_PIPELINE_V1: this guest action runs the canonical SideStore refresh pipeline.
    private actor OperationActor
    {
        private(set) var operation: BackgroundRefreshAppsOperation?
        
        func set(_ operation: BackgroundRefreshAppsOperation?)
        {
            self.operation = operation
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static let intentClassName = "RefreshAllIntent"
    
    static var title: LocalizedStringResource = "Refresh All Apps"
    static var openAppWhenRun = true
    static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    let presentsNotifications: Bool
    
    private let operationActor = OperationActor()
    
    init(presentsNotifications: Bool)
    {
        self.presentsNotifications = presentsNotifications
        
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }
    
    init()
    {
        self.init(presentsNotifications: false)
    }
    
    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        let trace = V3RefreshIntentBoundaryTrace()
        trace.record(.started)
        do
        {
            // Request foreground execution at ~27 seconds to gracefully handle timeout.
            let deadline: ContinuousClock.Instant = .now + .seconds(27)
            
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    trace.record(.pipelineStarted)
                    do {
                        try await self.refreshAllApps()
                        trace.record(.pipelineCompleted)
                    } catch {
                        trace.record(.pipelineThrew)
                        throw error
                    }
                }
                
                taskGroup.addTask {
                    try await Task.sleep(until: deadline)
                    trace.record(.deadlineElapsed)
                    throw OperationError.timedOut
                }
                
                do
                {
                    for try await _ in taskGroup.prefix(1)
                    {
                        // We only care about the first child task to complete.
                        taskGroup.cancelAll()
                        break
                    }
                }
                catch OperationError.timedOut
                {
                    // We took too long to finish and return the final result,
                    // so we'll now present a normal notification when finished.
                    let operation = await self.operationActor.operation
                    operation?.presentsFinishedNotification = true
                    
                    trace.record(.foregroundRequested)
                    do {
                        try await self.requestToContinueInForeground()
                        trace.record(.foregroundReturned)
                    } catch {
                        trace.record(.foregroundThrew)
                        throw error
                    }
                }
            }
            
            trace.record(.wrapperCompleted)
            return .result(dialog: "All apps have been refreshed.")
        }
        catch
        {
            trace.record(.wrapperThrew)
            let intentError = IntentError(V3HeadlessPairingFailure.tagIfInvalidPairing(error))
            throw intentError
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private extension RefreshAllAppsIntent
{
    func refreshAllApps() async throws {
        let ticket = try await V3SideStoreService.shared.beginExternalRefreshExecution()
        do {
            try await V3RefreshIntentBackend.run(presentsNotifications: self.presentsNotifications,
                progress: self.progress, ticket: ticket) { operation in
                    await self.operationActor.set(operation)
                }
            await V3SideStoreService.shared.endRefreshExecution(ticket)
        } catch {
            await V3SideStoreService.shared.endRefreshExecution(ticket)
            throw error
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
enum V3RefreshIntentBackend {
    static func run(presentsNotifications: Bool, progress: Progress,
                    ticket: V3RefreshExecutionTicket,
                    onStarted: @escaping @Sendable (BackgroundRefreshAppsOperation) async -> Void = { _ in }) async throws {
        try await V3SideStoreService.shared.validateRefreshExecution(ticket)

        try await DatabaseManager.shared.start()
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        
        try await V3SideStoreService.shared.validateRefreshExecution(ticket)
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = V3RefreshIntentStartPolicy.create({
                try AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: presentsNotifications) { (result) in
                do
                {
                    let results = try result.get()
                    
                    for (_, result) in results
                    {
                        guard case let .failure(error) = result else { continue }
                        throw V3HeadlessPairingFailure.tagIfInvalidPairing(error)
                    }
                    
                    continuation.resume()
                }
                catch OperationError.noInstalledApps
                {
                    continuation.resume()
                }
                catch
                {
                    continuation.resume(throwing: error)
                }
            }
            }, continuation: continuation,
                classify: V3HeadlessPairingFailure.tagIfInvalidPairing)
            guard let operation else { return }
            
            operation.ignoresServerNotFoundError = false
            
            progress.addChild(operation.progress, withPendingUnitCount: 1)
            
            Task {
                await onStarted(operation)
            }
        }
    }
}


// V3_REFRESH_INTENT_BOUNDARY_TRACE_V1: fixed local phases only. Never record
// native error text, domains, userInfo, credentials, account or device IDs.
private struct V3RefreshIntentBoundaryTrace: Sendable {
    enum Phase: String {
        case started, pipelineStarted, pipelineCompleted, pipelineThrew
        case deadlineElapsed, foregroundRequested, foregroundReturned, foregroundThrew
        case wrapperCompleted, wrapperThrew
    }
    // This random local trace tag is not an account/device/session identifier.
    private let tag = String(UUID().uuidString.prefix(8))
    private let started = DispatchTime.now().uptimeNanoseconds

    func record(_ phase: Phase) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= started ? min((now - started) / 1_000_000, 86_400_000) : 0
        print("[V3_REFRESH_INTENT] trace=\(tag) phase=\(phase.rawValue) elapsed_ms=\(elapsed)")
    }
}
