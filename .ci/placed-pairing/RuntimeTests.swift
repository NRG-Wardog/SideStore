import Foundation

@MainActor
func setup(_ content: String? = "SYNTHETIC_PAIRING_FIXTURE_ONLY:primary") throws -> PairingFileManager {
    FixtureHooks.onParse = nil; FixtureHooks.failUnlink = false
    FixtureStore.root = FileManager.default.temporaryDirectory.appendingPathComponent("placed-pairing-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: FixtureStore.root, withIntermediateDirectories: true)
    UserDefaults.standard.isPairingReset = true
    UserDefaults.standard.activePairingProtocol = nil
    UserDefaults.standard.preferredPairingProtocol = nil
    if let content { try content.write(to: FixtureStore.root.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName), atomically: true, encoding: .utf8) }
    return PairingFileManager()
}
@MainActor
func rejection(_ run: () throws -> Void) throws {
    var rejected = false
    do { try run() } catch { rejected = true }
    try expect(rejected)
}
@MainActor
func lifecycle(_ mode: String) async throws {
    let manager = try setup()
    let plan = try manager.preparePlacedImport()
    var active = false
    var commits = 0
    var rollbacks = 0
    let outcome = try await V3PlacedPairingLifecycle.run(
        validate: { try manager.validatePlacedImport(plan) },
        validateCommitted: { try manager.validateCommittedPlacedImport(plan) }, start: {
            active = true
            if mode == "stale" { try "SYNTHETIC_PAIRING_FIXTURE_ONLY:replacement".write(to: FixtureStore.root.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName), atomically: true, encoding: .utf8) }
            if mode == "preference" { UserDefaults.standard.preferredPairingProtocol = .rppairing }
            if mode == "start" || mode == "cleanup" { throw FixtureFailure.failed }
            if mode == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
        }, verify: {
            if mode == "identity" { throw FixtureFailure.failed }
            if mode == "afterVerify" { try "SYNTHETIC_PAIRING_FIXTURE_ONLY:changed".write(to: FixtureStore.root.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName), atomically: true, encoding: .utf8) }
        }, commit: { try manager.commitPlacedImport(plan); commits += 1 }, rollback: {
            rollbacks += 1
            if mode == "cleanup" { return false }
            active = false
            return true
        })
    try expect(commits == 1 && !UserDefaults.standard.isPairingReset)
    try expect(manager.fetchPairingFile(for: .lockdown) == plan.content)
    if mode == "success" {
        try expect(outcome == .ready && active && rollbacks == 0)
    } else {
        try expect(outcome == (mode == "cleanup" ? .cleanupUncertain : .connectionNotReady))
        try expect(rollbacks == 1)
        if mode != "cleanup" { try expect(!active) }
    }
}
@MainActor
func repeatSelection(_ mode: String) async throws {
    let manager = try setup()
    try manager.commitPlacedImport(manager.preparePlacedImport())
    let plan = try manager.preparePlacedImport()
    try expect(plan.isCurrentSelection)
    var commits = 0; var starts = 0; var probes = 0; var rollbacks = 0
    var ownsOperation = true
    var transportUnchanged = true
    var result: V3PlacedPairingOutcome?
    var rejected = false
    do {
        result = try await V3PlacedPairingLifecycle.run(
            alreadySelected: plan.isCurrentSelection,
            mayReuseTransport: mode != "missingReceipt",
            validateReusableTransport: { if !transportUnchanged { throw V3PlacedPairingError.stale } },
            validateOperation: { if !ownsOperation { throw V3PlacedPairingError.stale } },
            validate: { try manager.validatePlacedImport(plan) },
            validateCommitted: { try manager.validateCommittedPlacedImport(plan) },
            start: { starts += 1 },
            verify: {
                probes += 1
                if mode == "retry" && probes == 1 { throw FixtureFailure.failed }
                if mode == "unready" { throw FixtureFailure.failed }
                if mode == "reset" { UserDefaults.standard.isPairingReset = true }
                if mode == "source" {
                    try "SYNTHETIC_PAIRING_FIXTURE_ONLY:changed".write(
                        to: manager.pairingFileURL(for: .unknown), atomically: true, encoding: .utf8)
                }
                if mode == "destination" {
                    // Even identical bytes with a new identity must invalidate
                    // the prepared observation across the suspension.
                    try plan.content.write(to: manager.pairingFileURL(for: .lockdown),
                        atomically: true, encoding: .utf8)
                }
                if mode == "owner" { ownsOperation = false }
                if mode == "receipt" { transportUnchanged = false }
                if mode == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
            },
            commit: { commits += 1; try manager.commitPlacedImport(plan) },
            rollback: { rollbacks += 1; return true })
    } catch { rejected = true }
    try expect(commits == 0)
    switch mode {
    case "ready": try expect(result == .ready && starts == 0 && probes == 1 && rollbacks == 0)
    case "retry": try expect(result == .ready && starts == 1 && probes == 2 && rollbacks == 0)
    case "missingReceipt": try expect(result == .ready && starts == 1 && probes == 1 && rollbacks == 0)
    case "unready":
        try expect(result == .connectionNotReady && starts == 1 && probes == 2 && rollbacks == 1)
        try expect(manager.currentSelectionState() == .selected)
    default:
        try expect(rejected && result == nil && starts == 0 && probes == 1 && rollbacks == 0)
    }
}

@main struct PlacedPairingFixture {
    @MainActor static func main() async throws {
        var rows: [String] = []
        try await lifecycle("success"); rows.append("fresh-place-explicit-adoption")
        var manager = try setup()
        try expect(manager.fetchPairingFile() == nil && !manager.hasPairingFile() && UserDefaults.standard.isPairingReset)
        rows.append("boot-and-status-preserve-reset")
        manager = try setup("INVALID_SYNTHETIC_ONLY")
        try rejection { _ = try manager.preparePlacedImport() }
        try expect(UserDefaults.standard.isPairingReset); rows.append("invalid-placement-no-mutation")
        manager = try setup(nil)
        try rejection { _ = try manager.preparePlacedImport() }
        try expect(UserDefaults.standard.isPairingReset); rows.append("reset-with-no-file-preserved")
        for (mode, name) in [("stale", "changed-placement-after-commit-stops-transport"), ("preference", "changed-preference-after-commit-not-overwritten"), ("start", "failed-startup-retains-adopted-file"), ("cancel", "cancelled-startup-retains-adopted-file"), ("identity", "failed-live-identity-retains-adopted-file"), ("cleanup", "cleanup-uncertainty-retains-file-and-hold")] {
            try await Task { @MainActor in try await lifecycle(mode) }.value
            rows.append(name)
        }
        manager = try setup()
        let conflicting = FixtureStore.root.appendingPathComponent(AppConstants.Pairing.lockdownPairingFileName)
        try "SYNTHETIC_PAIRING_FIXTURE_ONLY:unrelated".write(to: conflicting, atomically: true, encoding: .utf8)
        try rejection { _ = try manager.preparePlacedImport() }
        let retained = try String(contentsOf: conflicting)
        try expect(retained == "SYNTHETIC_PAIRING_FIXTURE_ONLY:unrelated"); rows.append("conflicting-destination-preserved")
        manager = try setup(nil)
        let outside = FixtureStore.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try "SYNTHETIC_PAIRING_FIXTURE_ONLY:outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: FixtureStore.root.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName), withDestinationURL: outside)
        try rejection { _ = try manager.preparePlacedImport() }; rows.append("symlink-placement-rejected")
        let alias = FixtureStore.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: FixtureStore.root)
        try rejection { _ = try V3PlacedPairingDirectory(root: alias) }; rows.append("symlink-directory-rejected")
        manager = try setup(String(repeating: "x", count: V3PlacedPairingDirectory.maximumBytes + 1))
        try rejection { _ = try manager.preparePlacedImport() }; rows.append("oversized-file-rejected")
        manager = try setup()
        var plan = try manager.preparePlacedImport()
        try FileManager.default.moveItem(at: FixtureStore.root, to: FixtureStore.root.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: FixtureStore.root, withIntermediateDirectories: true)
        try rejection { try manager.commitPlacedImport(plan) }; rows.append("directory-replacement-rejected")
        manager = try setup(); plan = try manager.preparePlacedImport()
        try "SYNTHETIC_PAIRING_FIXTURE_ONLY:changed".write(to: FixtureStore.root.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName), atomically: true, encoding: .utf8)
        try rejection { try manager.commitPlacedImport(plan) }
        try expect(UserDefaults.standard.isPairingReset && !manager.hasPairingFile(for: .lockdown)); rows.append("stale-before-commit-no-adoption")
        manager = try setup()
        try FileManager.default.copyItem(at: FixtureStore.root.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName), to: manager.pairingFileURL(for: .lockdown))
        try manager.commitPlacedImport(manager.preparePlacedImport())
        try expect(!UserDefaults.standard.isPairingReset); rows.append("verified-existing-copy-adopted")
        manager = try setup()
        let cancelPlan = try manager.preparePlacedImport(); let cancelManager = manager
        try await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try rejection { try cancelManager.commitPlacedImport(cancelPlan) }
        }.value
        try expect(UserDefaults.standard.isPairingReset && !manager.hasPairingFile(for: .lockdown)); rows.append("commit-cancellation-preserves-reset")
        var concurrent = 0; var maximum = 0
        let first = Task { @MainActor in try await V3PairingActivationGate.withExclusiveAccess {
            concurrent += 1; maximum = max(maximum, concurrent)
            try await Task.sleep(nanoseconds: 60_000_000); concurrent -= 1
        } }
        let second = Task { @MainActor in try await V3PairingActivationGate.withExclusiveAccess {
            concurrent += 1; maximum = max(maximum, concurrent); concurrent -= 1
        } }
        try await first.value; try await second.value
        try expect(maximum == 1); rows.append("activation-gate-serializes")
        try expect(!FixtureStore.logs.joined().contains("SYNTHETIC_PAIRING_FIXTURE_ONLY") && !FixtureStore.logs.joined().contains("fixture-device"))
        rows.append("diagnostics-do-not-contain-pairing-data")
        FixtureGateway.failLive = true; FixtureGateway.live = "fixture-device"; FixtureGateway.cachedFetches = 0
        var rejected = false
        do { try await V3PlacedPairingReadiness.verify(expectedUDID: "fixture-device") } catch { rejected = true }
        try expect(rejected && FixtureGateway.cachedFetches == 0); rows.append("cached-device-id-is-not-live-proof")
        FixtureGateway.failLive = false; FixtureGateway.live = "other-fixture-device"; rejected = false
        do { try await V3PlacedPairingReadiness.verify(expectedUDID: "fixture-device") } catch { rejected = true }
        try expect(rejected); rows.append("different-live-device-not-ready")
        FixtureGateway.live = "fixture-device"
        try await V3PlacedPairingReadiness.verify(expectedUDID: "fixture-device")
        try expect(FixtureGateway.cachedFetches == 0 && FixtureCore.batchDepth == 0); rows.append("actual-live-query-ready")
        manager = try setup(); UserDefaults.standard.isPairingReset = false
        plan = try manager.preparePlacedImport()
        FixtureHooks.onParse = {
            FixtureHooks.onParse = nil
            try! "SYNTHETIC_PAIRING_FIXTURE_ONLY:changed".write(to: FixtureStore.root.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName), atomically: true, encoding: .utf8)
        }
        FixtureHooks.failUnlink = true
        var cleanupFailed = false
        do { try manager.commitPlacedImport(plan) } catch { cleanupFailed = error as? V3PlacedPairingError == .cleanupFailed }
        FixtureHooks.failUnlink = false
        try expect(cleanupFailed && UserDefaults.standard.isPairingReset && manager.fetchPairingFile() == nil)
        try expect(manager.hasPairingFile(for: .lockdown)); rows.append("failed-publication-cleanup-quarantines-leftover")
        try await lifecycle("afterVerify"); rows.append("changed-state-after-live-query-not-ready")
        for (mode, name) in [("start", "queued-boot-does-not-retry-not-ready"), ("cleanup", "queued-boot-does-not-override-cleanup-uncertain")] {
            V3PairingActivationGate.placementOwnsStartup = false
            var bootStarts = 0
            let activation = Task { @MainActor in
                try await V3PairingActivationGate.withExclusiveAccess {
                    let local = try setup()
                    let plan = try local.preparePlacedImport()
                    _ = try await V3PlacedPairingLifecycle.run(
                        validate: { try local.validatePlacedImport(plan) },
                        validateCommitted: { try local.validateCommittedPlacedImport(plan) },
                        start: { try await Task.sleep(nanoseconds: 60_000_000); throw FixtureFailure.failed },
                        verify: {}, commit: {
                            try local.commitPlacedImport(plan)
                            V3PairingActivationGate.placementOwnsStartup = true
                        }, rollback: { mode != "cleanup" })
                }
            }
            let queuedBoot = Task { @MainActor in
                try await Task.sleep(nanoseconds: 10_000_000)
                try await V3PairingActivationGate.runBootIfNeeded { bootStarts += 1 }
            }
            try await activation.value; try await queuedBoot.value
            try expect(bootStarts == 0 && V3PairingActivationGate.placementOwnsStartup)
            rows.append(name)
        }
        manager = try setup()
        try manager.commitPlacedImport(manager.preparePlacedImport())
        let selectedBefore = try V3PlacedPairingDirectory(root: FixtureStore.root)
            .read(AppConstants.Pairing.lockdownPairingFileName)
        try expect(manager.currentSelectionState() == .selected)
        try expect(PairingFileManager().currentSelectionState() == .selected)
        let selectedAfter = try V3PlacedPairingDirectory(root: FixtureStore.root)
            .read(AppConstants.Pairing.lockdownPairingFileName)
        try expect(selectedBefore == selectedAfter && !UserDefaults.standard.isPairingReset)
        rows.append("saved-selection-restores-from-safe-file")
        try FileManager.default.removeItem(at: manager.pairingFileURL(for: .lockdown))
        try expect(manager.currentSelectionState() == .missing)
        rows.append("selected-file-missing")
        manager = try setup(); try manager.commitPlacedImport(manager.preparePlacedImport())
        UserDefaults.standard.isPairingReset = true
        try expect(manager.currentSelectionState() == .reset)
        let resetPlan = try manager.preparePlacedImport()
        try expect(!resetPlan.isCurrentSelection)
        try expect(UserDefaults.standard.isPairingReset)
        rows.append("reset-leftover-not-selected")
        manager = try setup(); try manager.commitPlacedImport(manager.preparePlacedImport())
        try "SYNTHETIC_PAIRING_FIXTURE_ONLY:new".write(to: manager.pairingFileURL(for: .unknown), atomically: true, encoding: .utf8)
        try expect(manager.currentSelectionState() == .changed)
        try rejection { _ = try manager.preparePlacedImport() }
        rows.append("changed-source-not-selected")
        manager = try setup(); try manager.commitPlacedImport(manager.preparePlacedImport())
        UserDefaults.standard.preferredPairingProtocol = .rppairing
        try expect(manager.currentSelectionState() == .changed)
        rows.append("changed-preference-not-selected")
        manager = try setup(); try manager.commitPlacedImport(manager.preparePlacedImport())
        try "INVALID_SYNTHETIC_ONLY".write(to: manager.pairingFileURL(for: .lockdown), atomically: true, encoding: .utf8)
        try expect(manager.currentSelectionState() == .invalid)
        rows.append("malformed-selected-file-no-green")
        manager = try setup(); try manager.commitPlacedImport(manager.preparePlacedImport())
        try FileManager.default.removeItem(at: manager.pairingFileURL(for: .lockdown))
        try FileManager.default.createSymbolicLink(at: manager.pairingFileURL(for: .lockdown), withDestinationURL: manager.pairingFileURL(for: .unknown))
        try expect(manager.currentSelectionState() == .unknown)
        rows.append("unsafe-selected-file-no-green")
        manager = try setup(); try manager.commitPlacedImport(manager.preparePlacedImport())
        try FileManager.default.removeItem(at: manager.pairingFileURL(for: .unknown))
        try expect(manager.currentSelectionState() == .selected)
        try rejection { _ = try manager.preparePlacedImport() }
        rows.append("source-removed-saved-selection-retained")
        for (mode, name) in [("ready", "repeated-identical-selection-no-restart"),
                             ("retry", "repeated-unready-selection-retries-without-commit"),
                             ("unready", "repeated-unready-selection-retains-file"),
                             ("reset", "reset-during-probe-no-ready"),
                             ("source", "changed-source-during-probe-no-ready"),
                             ("destination", "changed-destination-during-probe-no-ready"),
                             ("owner", "owner-change-during-probe-no-ready"),
                             ("cancel", "cancelled-probe-no-restart")] {
            try await Task { @MainActor in try await repeatSelection(mode) }.value
            rows.append(name)
        }
        try expect(!V3PairingSelectionPresentation.isSaved(connected: true, observed: false, selection: "selected"))
        try expect(V3PairingSelectionPresentation.isSaved(connected: true, observed: true, selection: "selected"))
        try expect(!V3PairingSelectionPresentation.isSaved(connected: false, observed: true, selection: "selected"))
        try expect(V3PairingSelectionPresentation.detail(connected: true, observed: true, selection: "selected") == "Pairing file saved and selected.")
        rows.append("view-reentry-file-only-status")
        for state in ["available", "reset", "missing", "changed", "invalid", "unknown", "adoptedReady", "futureValue"] {
            try expect(!V3PairingSelectionPresentation.isSaved(connected: true, observed: true, selection: state))
        }
        rows.append("unknown-selection-never-green")
        try await repeatSelection("missingReceipt")
        rows.append("missing-receipt-restarts-without-recommit")
        try await repeatSelection("receipt")
        rows.append("changed-receipt-during-probe-no-ready")
        let receipt = V3PairingTransportReceipt()
        let startup = receipt.invalidate()
        try expect(receipt.ticket(contents: "SYNTHETIC_ONLY", mode: .lockdown) == nil)
        receipt.recordStarted(generation: startup, contents: "SYNTHETIC_ONLY", mode: .lockdown)
        try expect(receipt.ticket(contents: "SYNTHETIC_ONLY", mode: .lockdown) == startup)
        try expect(receipt.ticket(contents: "SYNTHETIC_CHANGED", mode: .lockdown) == nil)
        try expect(receipt.ticket(contents: "SYNTHETIC_ONLY", mode: .rppairing) == nil)
        rows.append("transport-receipt-binds-input-and-protocol")
        receipt.invalidate()
        receipt.recordStarted(generation: startup, contents: "SYNTHETIC_ONLY", mode: .lockdown)
        try expect(receipt.ticket(contents: "SYNTHETIC_ONLY", mode: .lockdown) == nil)
        let current = receipt.invalidate()
        receipt.recordStarted(generation: current, contents: "SYNTHETIC_ONLY", mode: .unknown)
        try expect(receipt.ticket(contents: "SYNTHETIC_ONLY", mode: .unknown) == nil)
        rows.append("stale-start-cannot-revive-receipt")
        try expect(rows.count == 49 && Set(rows).count == rows.count)
        let report: [String: Any] = ["schema": "placed-pairing-cases-v1", "fake_only": true, "cases": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count == 2 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print("PLACED_PAIRING_FIXTURE_PASS")
    }
}
