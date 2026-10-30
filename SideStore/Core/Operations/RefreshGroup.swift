//
//  RefreshGroup.swift
//  AltStore
//
//  Created by Riley Testut on 6/20/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
import SideSign

// V3_OWNED_TRANSPORT_OBSERVATION_V1: historical, run-bound native readiness.
// This is not installation acknowledgement or a claim of current connectivity.
struct V3OwnedTransportObservation {
    private var runID: String?
    private var ready = false

    mutating func bind(to value: String) {
        guard runID == nil, UUID(uuidString: value) != nil else { return }
        runID = value
    }

    mutating func recordReady(nativeReady: Bool, configurationUnchanged: Bool,
                              checkOwnership: () throws -> Void) rethrows {
        try checkOwnership()
        guard runID != nil, nativeReady, configurationUnchanged else { return }
        ready = true
    }

    func wire(for value: String) -> [String: Any]? {
        guard ready, runID == value else { return nil }
        return ["version": 1, "readiness": "ready", "scope": "ownedBatch"]
    }
}
// V3_OWNED_TRANSPORT_OBSERVATION_END

final class RefreshGroup: NSObject
{
    let context: StandaloneOperationContext
    var dbContext: NSManagedObjectContext { context.dbBackgroundContext }
    let sharedContext: SharedPipelineContext
    let progress = Progress.discreteProgress(totalUnitCount: 100)
    var error: Error? {
        get { context.error }
        set { context.error = newValue }
    }
    var isCellularRefreshGroup: Bool = false
    var operationStartTime: CFAbsoluteTime { context.operationStartTime }
    
    var completionHandler: (([String: Result<InstalledApp, Error>]) -> Void)?
    var beginInstallationHandler: ((InstalledApp) -> Void)?
        
    private var transportObservation = V3OwnedTransportObservation()

    func bindTransportObservation(to runID: String) {
        lock.withLock { transportObservation.bind(to: runID) }
    }

    func recordTransportReady(nativeReady: Bool, configurationUnchanged: Bool,
                              checkOwnership: () throws -> Void) rethrows {
        try lock.withLock {
            try transportObservation.recordReady(nativeReady: nativeReady,
                configurationUnchanged: configurationUnchanged, checkOwnership: checkOwnership)
        }
    }

    func transportObservationWire(for runID: String) -> [String: Any]? {
        lock.withLock { transportObservation.wire(for: runID) }
    }

    private var verificationByApp: [String: V3RefreshVerification] = [:]

    func setVerification(_ value: V3RefreshVerification, for bundleID: String) {
        lock.withLock {
            if let prior = verificationByApp[bundleID],
               (prior.mutationDispatched && !value.mutationDispatched) ||
               (prior.installAcknowledged && !value.installAcknowledged) { return }
            verificationByApp[bundleID] = value
        }
    }

    func verification(for bundleID: String) -> V3RefreshVerification? {
        lock.withLock { verificationByApp[bundleID] }
    }

    func verificationSnapshot() -> [String: V3RefreshVerification] {
        lock.withLock { verificationByApp }
    }

    private(set) var results = [String: Result<InstalledApp, Error>]()
    
    // Keep strong references to managed object contexts
    // so they don't die out from under us.
    private(set) var retainedContexts = Set<NSManagedObjectContext>()
    
    var activeTask: Task<Void, Never>?
    private let lock = NSLock()
    
    convenience init(dbContext: NSManagedObjectContext, sharedContext: SharedPipelineContext = SharedPipelineContext()) {
        self.init(context: StandaloneOperationContext(steps: [], dbBackgroundContext: dbContext), sharedContext: sharedContext)
    }

    init(context: StandaloneOperationContext, sharedContext: SharedPipelineContext = SharedPipelineContext())
    {
        self.context = context
        self.sharedContext = sharedContext
        super.init()
    }
    
    func set(_ result: Result<InstalledApp, Error>, forAppWithBundleIdentifier bundleIdentifier: String)
    {
        self.lock.withLock {
            self.results[bundleIdentifier] = result
            
            switch result
            {
            case .failure: break
            case .success(let installedApp):
                guard let context = installedApp.managedObjectContext else { break }
                self.retainedContexts.insert(context)
            }
        }
    }
    
    func cancel()
    {
        self.activeTask?.cancel()
    }
}
