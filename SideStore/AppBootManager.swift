//
//  AppBootManager.swift
//  SideStore
//
//  Created by Magesh K on 9/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Minimuxer

public final class AppBootManager {
    public static let shared = AppBootManager()
    
    // V3_HEADLESS_BOOT_UI_STATE_REMOVED_V1: prompt state belongs to the excluded launch controller.

    private init() {}
    

    public nonisolated func startMinimuxer(pairingFile: String) async throws {
        try await V3PairingActivationGate.withExclusiveAccess {
            try await self.startMinimuxerUnlocked(pairingFile: pairingFile)
        }
    }

    private nonisolated func startMinimuxerUnlocked(pairingFile: String, verifyLiveIdentity: Bool = true) async throws {
        debugLog("[AppBootManager] startMinimuxer() entered")
        defer { debugLog("[AppBootManager] startMinimuxer() exited") }
        
        if UserDefaults.standard.enableEMPforWireguard {
            debugLog("[AppBootManager] Starting EMProxy before minimuxer...")
            try await startEMProxy()
        }

        try await minimuxerStart(pairingFile, preferred: PairingFileManager.shared.preferredProtocol)
        
        // Placement labels readiness with a direct query, without persisting
        // cached identity here. Ordinary boot retains its original behavior.
        guard verifyLiveIdentity else { return }
        // Validate the pairing by trying to fetch the UDID
        do {
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection starting...")
            _ = try await fetchUDID(forceLive: true)
            debugLog("[AppBootManager] Live device identity check succeeded; identifier omitted.")
        } catch {
            if case MinimuxerError.invalidPairing = error {
                debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test FAILED. \(error)")
                throw error
            } else {
                debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test FAILED but PAIRING FILE IS VALID. \(error)")
            }
        }
    }
    
    @MainActor
    func usePlacedPairingFile() async throws -> V3PlacedPairingOutcome {
        return try await V3PairingActivationGate.withExclusiveAccess {
            let manager = PairingFileManager.shared
            let plan = try manager.preparePlacedImport()
            return try await V3PlacedPairingLifecycle.run(
                validate: { try manager.validatePlacedImport(plan) },
                validateCommitted: { try manager.validateCommittedPlacedImport(plan) },
                start: {
                    // start() alone does not prove an old transport was retired.
                    try await minimuxerStop()
                    try await self.startMinimuxerUnlocked(pairingFile: plan.content, verifyLiveIdentity: false)
                },
                verify: { try await V3PlacedPairingReadiness.verify(expectedUDID: plan.expectedUDID) },
                commit: {
                    try manager.commitPlacedImport(plan)
                    V3PairingActivationGate.placementOwnsStartup = true
                },
                rollback: {
                    // Retire provisional transport even when the request task
                    // was cancelled. Never leave new identity active on failure.
                    var stopped = true
                    do { try await minimuxerStop() } catch { stopped = false }
                    if UserDefaults.standard.enableEMPforWireguard {
                        do { try await stopEMProxy() } catch { stopped = false }
                    }
                    return stopped
                })
        }
    }

    // V3_HEADLESS_BOOT_PAIRING_PROMPT_REMOVED_V1

    
    public nonisolated func performBootSequence() async {
        debugLog("[AppBootManager] performBootSequence() entered")
        defer {
            debugLog("[AppBootManager] performBootSequence() exited")
        }
        
        // 1. Structured concurrent child task A
        async let jitCheck: Void = {
            debugLog("[AppBootManager] performBootSequence(): JIT check starting")
            defer {
                debugLog("[AppBootManager] performBootSequence(): JIT check completed")
            }
            // V3_HEADLESS_BOOT_SIDEJIT_DETECTION_REMOVED_V1: configured SideJIT network requests remain below.

            if #available(iOS 17, *), UserDefaults.standard.isSideJITServerEnabled {
                await SideJITManager.shared.askForNetwork()
                debugLog("[AppBootManager] SideJITServer Enabled")
            }
        }()
        
        // 2. Structured concurrent child task B
        async let minimuxerCheck: Void = {
            debugLog("[AppBootManager] performBootSequence(): Minimuxer check starting")
            defer {
                debugLog("[AppBootManager] performBootSequence(): Minimuxer check completed")
            }
            #if targetEnvironment(simulator)
            do {
                try await self.startMinimuxer(pairingFile: "ignored-for-sim")
            } catch {
                debugLog("[AppBootManager] Failed to start minimuxer: \(error)")
            }
            #else
            do {
                try await V3PairingActivationGate.runBootIfNeeded {
                    // Read only after acquiring ownership: a queued boot must
                    // not restart an obsolete file after explicit placement.
                    if let pf = PairingFileManager.shared.fetchPairingFile() {
                        try await self.startMinimuxerUnlocked(pairingFile: pf)
                    }
                }
            } catch {
                debugLog("[AppBootManager] Failed to start minimuxer: \(error)")
            }
            #endif
        }()
        
        // Await both concurrently (Structured Concurrency awaits them in parallel)
        _ = await (jitCheck, minimuxerCheck)
    }
}

// Shared only by boot/startup and explicit placement. No protocol default or
// reset policy is changed. The body retains ownership across suspension.
@MainActor
enum V3PairingActivationGate {
    private static var occupied = false
    static var placementOwnsStartup = false

    static func runBootIfNeeded(_ body: @MainActor () async throws -> Void) async throws {
        try await withExclusiveAccess {
            // A queued boot must not undo explicit activation's cleanup or
            // retry readiness after the user cancelled. New processes start false.
            guard !placementOwnsStartup else { return }
            try await body()
        }
    }

    static func withExclusiveAccess<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        while occupied { try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
        occupied = true
        defer { occupied = false }
        return try await body()
    }
}

// V3_PLACED_PAIRING_LIFECYCLE_V1: test the actual ordered transaction with fake
// transport boundaries. Native/device testing is still required before release.
enum V3PlacedPairingOutcome: String {
    case ready = "adoptedReady"
    case connectionNotReady = "adoptedConnectionNotReady"
    case cleanupUncertain = "adoptedCleanupUncertain"
}

@MainActor
enum V3PlacedPairingReadiness {
    static func verify(expectedUDID: String?) async throws {
        await minimuxer.core.beginTransportBatch()
        do {
            try await ensureMinimuxerReady()
            // fetchUDID may return a cached pairing ID in some backends. Only
            // a fresh lockdown query can label this activation live-ready.
            let live = try await minimuxer.gateway.getLockdownValue(key: "UniqueDeviceID")
            guard !live.isEmpty, live != "XXXXX-XXXX-XXXXX-XXXX",
                  expectedUDID == nil || expectedUDID == live else {
                throw V3PlacedPairingError.startupFailed
            }
            await minimuxer.core.endTransportBatch()
        } catch {
            await minimuxer.core.endTransportBatch()
            throw error
        }
    }
}

@MainActor
enum V3PlacedPairingLifecycle {
    static func run(validate: @MainActor () throws -> Void,
                    validateCommitted: @MainActor () throws -> Void,
                    start: @MainActor () async throws -> Void,
                    verify: @MainActor () async throws -> Void,
                    commit: @MainActor () throws -> Void,
                    rollback: @escaping @MainActor () async -> Bool) async throws -> V3PlacedPairingOutcome {
        try Task.checkCancellation()
        try validate()
        // Explicit file adoption is the linearization point, like manual
        // import. A VPN/network problem must not turn it back into "missing".
        try commit()
        do {
            try Task.checkCancellation()
            try validateCommitted()
            try await start()
            try Task.checkCancellation()
            try validateCommitted()
            try await verify()
            try Task.checkCancellation()
            try validateCommitted()
            return .ready
        } catch {
            // The file is already committed. Cancellation/failure retires only
            // provisional transport; it does not pretend to undo that import.
            let stopped = await Task { @MainActor in await rollback() }.value
            return stopped ? .connectionNotReady : .cleanupUncertain
        }
    }
}
