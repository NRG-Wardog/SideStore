struct FixtureFailure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure(message: message) }
}
let fm = FileManager.default
let original = "com.fixture.host"
let resigned = "com.fixture.host.FIXTURETEAM"
let identity = V3HostRefreshBundlePreparation.ExtensionIdentity(original: original + ".widget", resigned: resigned + ".widget")

func writeBundle(_ url: URL, id: String, withExtension: Bool = false) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Synthetic fixture", "CFBundleExecutable": "fixture", "FixtureUnchanged": ["nested": 7]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
    try Data("SYNTHETIC-EXECUTABLE-ENTITLEMENTS".utf8).write(to: url.appendingPathComponent("fixture"))
    try Data("SYNTHETIC-PROFILE-NOT-A-CREDENTIAL".utf8).write(to: url.appendingPathComponent("embedded.mobileprovision"))
    try Data("hidden-exact-content".utf8).write(to: url.appendingPathComponent(".hidden"))
    if withExtension { try writeBundle(url.appendingPathComponent("PlugIns/Widget.appex"), id: id + ".widget") }
}
func prepare(_ source: URL, _ temp: URL,
             originalID: String = original, resignedID: String = resigned,
             activeID: String = resigned,
             extensions: [V3HostRefreshBundlePreparation.ExtensionIdentity] = [identity],
             check: () throws -> Void = {}) throws -> V3HostRefreshBundlePreparation.Prepared {
    try V3HostRefreshBundlePreparation.prepare(originalBundleID: originalID,
        resignedBundleID: resignedID, expectedOriginalBundleID: original, activeBundleID: activeID,
        activeBundleURL: source, extensions: extensions, temporaryDirectory: temp, checkAdmission: check)
}
func noOwnedCopies(_ temp: URL) -> Bool {
    ((try? fm.contentsOfDirectory(atPath: temp.path)) ?? []).allSatisfy { !$0.hasPrefix("v3-host-refresh-") }
}
func expectFailure(_ body: () async throws -> Void) async throws {
    var failed = false
    do { try await body() } catch { failed = true }
    try require(failed, "Expected fail-closed preparation")
}

func runFixture() async throws -> [String] {
    let root = fm.temporaryDirectory.appendingPathComponent("host-refresh-fixture-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("LiveHost.app")
    let temp = root.appendingPathComponent("scratch")
    try fm.createDirectory(at: temp, withIntermediateDirectories: false)
    try writeBundle(source, id: resigned, withExtension: true)
    let before = AppBundleFingerprint.compute(for: source)
    try require(before != nil, "Synthetic source fingerprint")
    var cases: [String] = []
    func record(_ name: String, _ work: () async throws -> Void) async throws { try await work(); cases.append(name) }

    try await record("baseline_missing_cache_has_nil_target") {
        // This is the exact pre-fix target load performed by PipelineRunner.
        let missingCache = root.appendingPathComponent("missing-cache/App.app")
        let beforeTarget = ALTApplication(fileURL: missingCache)
        try require(beforeTarget == nil, "Baseline must reproduce missingTargetAppBundle input")
    }
    try await record("canonical_host_recovers_without_mutating_source") {
        let prepared = try prepare(source, temp)
        defer { prepared.removeOwnedCopy() }
        try require(prepared.appBundle.bundleIdentifier == original, "Canonical main ID")
        try require(prepared.appBundle.appExtensions.map { $0.bundleIdentifier } == [original + ".widget"], "Canonical extension ID")
        try require(AppBundleFingerprint.compute(for: source) == before, "Installed source unchanged")
        for relative in ["fixture", "embedded.mobileprovision", ".hidden", "PlugIns/Widget.appex/fixture", "PlugIns/Widget.appex/embedded.mobileprovision"] {
            let a = try Data(contentsOf: source.appendingPathComponent(relative))
            let b = try Data(contentsOf: prepared.appBundle.fileURL.appendingPathComponent(relative))
            try require(a == b, "Signed/non-plist bytes unchanged")
        }
        let plistData = try Data(contentsOf: prepared.appBundle.fileURL.appendingPathComponent("Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        try require((plist["FixtureUnchanged"] as? [String: Int]) == ["nested": 7], "Unrelated plist metadata unchanged")
    }
    try await record("success_cleanup_preserves_unowned_files") {
        let sentinel = temp.appendingPathComponent("unowned")
        try Data("keep".utf8).write(to: sentinel)
        try require(noOwnedCopies(temp) && fm.fileExists(atPath: sentinel.path), "Only owned scratch is removed")
    }
    try await record("original_identity_mismatch_rejected") { try await expectFailure { _ = try prepare(source, temp, originalID: "com.other.app") } }
    try await record("resigned_identity_mismatch_rejected") { try await expectFailure { _ = try prepare(source, temp, resignedID: "com.other.app") } }
    try await record("active_identity_mismatch_rejected") { try await expectFailure { _ = try prepare(source, temp, activeID: "com.other.app") } }
    try await record("missing_active_bundle_rejected") { try await expectFailure { _ = try prepare(root.appendingPathComponent("absent"), temp) } }
    try await record("missing_profile_rejected") {
        let profile = source.appendingPathComponent("embedded.mobileprovision")
        let data = try Data(contentsOf: profile)
        try fm.removeItem(at: profile)
        defer { try? data.write(to: profile) }
        try await expectFailure { _ = try prepare(source, temp) }
    }
    try await record("missing_extension_record_rejected") { try await expectFailure { _ = try prepare(source, temp, extensions: []) } }
    try await record("extra_extension_record_rejected") {
        let extra = V3HostRefreshBundlePreparation.ExtensionIdentity(original: original + ".extra", resigned: resigned + ".extra")
        try await expectFailure { _ = try prepare(source, temp, extensions: [identity, extra]) }
    }
    try await record("duplicate_extension_record_rejected") { try await expectFailure { _ = try prepare(source, temp, extensions: [identity, identity]) } }
    try await record("extension_suffix_mismatch_rejected") {
        let bad = V3HostRefreshBundlePreparation.ExtensionIdentity(original: original + ".other", resigned: resigned + ".widget")
        try await expectFailure { _ = try prepare(source, temp, extensions: [bad]) }
    }
    try await record("unsupported_symlink_still_rejected") {
        let link = source.appendingPathComponent("unsupported-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source.appendingPathComponent("fixture"))
        defer { try? fm.removeItem(at: link) }
        try await expectFailure { _ = try prepare(source, temp) }
        try require(noOwnedCopies(temp), "Unsupported source never copied")
    }
    try await record("source_changed_during_copy_rejected_and_cleaned") {
        let binary = source.appendingPathComponent("fixture")
        let data = try Data(contentsOf: binary)
        defer { try? data.write(to: binary) }
        var checkpoint = 0
        try await expectFailure {
            _ = try prepare(source, temp, check: {
                checkpoint += 1
                if checkpoint == 3 { try Data("changed".utf8).write(to: binary) }
            })
        }
        try require(noOwnedCopies(temp), "Changed-source scratch cleaned")
    }
    try await record("corrupted_copy_rejected_and_cleaned") {
        var checkpoint = 0
        try await expectFailure {
            _ = try prepare(source, temp, check: {
                checkpoint += 1
                if checkpoint == 3 {
                    let owner = try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("v3-host-refresh-") }!
                    try Data("corrupt".utf8).write(to: owner.appendingPathComponent("App.app/fixture"))
                }
            })
        }
        try require(noOwnedCopies(temp), "Corrupt-copy scratch cleaned")
    }
    for checkpointToCancel in 1...5 {
        try await record("cancellation_checkpoint_\(checkpointToCancel)_preserved_and_cleaned") {
            var checkpoint = 0
            var cancelled = false
            do {
                _ = try prepare(source, temp, check: {
                    checkpoint += 1
                    if checkpoint == checkpointToCancel { throw CancellationError() }
                })
            } catch is CancellationError { cancelled = true }
            try require(cancelled && noOwnedCopies(temp), "Cancellation must escape unchanged and clean owned scratch")
        }
    }
    try await record("revoked_admission_preserved_and_cleaned") {
        var checkpoint = 0
        var revoked = false
        do {
            _ = try prepare(source, temp, check: {
                checkpoint += 1
                if checkpoint == 3 { throw FixtureFailure(message: "revoked") }
            })
        } catch let failure as FixtureFailure { revoked = failure.message == "revoked" }
        try require(revoked && noOwnedCopies(temp), "Admission failure must escape unchanged")
    }
    try await record("repeated_refresh_has_independent_owned_copies") {
        let first = try prepare(source, temp)
        defer { first.removeOwnedCopy() }
        let second = try prepare(source, temp)
        defer { second.removeOwnedCopy() }
        try require(first.ownedDirectory != second.ownedDirectory, "Independent owners")
        try require(AppBundleFingerprint.compute(for: first.appBundle.fileURL) == AppBundleFingerprint.compute(for: second.appBundle.fileURL), "Deterministic canonical bytes")
        first.removeOwnedCopy()
        try require(fm.fileExists(atPath: second.appBundle.fileURL.path), "One owner cannot delete another")
    }
    try await record("concurrent_refresh_owners_do_not_collide") {
        final class Outcomes: @unchecked Sendable {
            let lock = NSLock()
            var copies: [V3HostRefreshBundlePreparation.Prepared] = []
            var errors: [Error] = []
        }
        let outcome = Outcomes()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let copy = try prepare(source, temp)
                    outcome.lock.lock(); outcome.copies.append(copy); outcome.lock.unlock()
                } catch { outcome.lock.lock(); outcome.errors.append(error); outcome.lock.unlock() }
            }
        }
        group.wait()
        defer { outcome.copies.forEach { $0.removeOwnedCopy() } }
        try require(outcome.errors.isEmpty && outcome.copies.count == 2, "Concurrent preparation succeeds")
        try require(Set(outcome.copies.map { $0.ownedDirectory }).count == 2, "Concurrent ownership unique")
        try require(AppBundleFingerprint.compute(for: source) == before, "Concurrent source remains untouched")
    }
    Bundle.Info.activeBundleURL = source
    let installed = InstalledApp(fileURL: root.appendingPathComponent("absent-cache/App.app"),
        bundleIdentifier: original, resignedBundleIdentifier: resigned,
        appExtensions: [.init(bundleIdentifier: identity.original, resignedBundleIdentifier: identity.resigned)])
    try await record("integration_refresh_missing_cache_prepares_and_cleans") {
        let context = FixtureContext()
        var preparedPath: URL?
        try await runIntegration(operation: .refresh(installed), context: context) { context in
            preparedPath = context.targetAppBundle?.fileURL
            try require(context.targetAppBundle?.bundleIdentifier == original, "Actual integration fills target")
            try require(context.customBundleIdentifier == installed.customBundleIdentifier && context.appBundleFingerprint == installed.appBundleFingerprint && context.useMainProfile == installed.useMainProfile, "Context identity and signing preferences retained")
            try require(preparedPath != source && fm.fileExists(atPath: preparedPath!.path), "Copy lives during pipeline scope")
        }
        try require(preparedPath != nil && !fm.fileExists(atPath: preparedPath!.path), "Actual integration defer cleans success")
    }
    try await record("integration_nonrefresh_does_not_recover") {
        try await runIntegration(operation: .other(installed), context: FixtureContext()) { context in
            try require(context.targetAppBundle == nil, "Non-refresh path unchanged")
        }
    }
    try await record("integration_nonself_does_not_recover") {
        let other = InstalledApp(fileURL: installed.fileURL, bundleIdentifier: "com.fixture.other",
            resignedBundleIdentifier: resigned, appExtensions: installed.appExtensions)
        try await runIntegration(operation: .refresh(other), context: FixtureContext()) { context in
            try require(context.targetAppBundle == nil, "Non-self path unchanged")
        }
    }
    try await record("integration_valid_cache_is_preserved") {
        let cached = InstalledApp(fileURL: source, bundleIdentifier: original,
            resignedBundleIdentifier: "ignored-on-existing-cache", appExtensions: [])
        try await runIntegration(operation: .refresh(cached), context: FixtureContext()) { context in
            try require(context.targetAppBundle?.fileURL == source, "Existing target untouched")
        }
        try require(fm.fileExists(atPath: source.path), "No cleanup owns existing cache")
    }
    try await record("integration_pipeline_failure_cleans_copy") {
        var preparedPath: URL?
        try await expectFailure {
            try await runIntegration(operation: .refresh(installed), context: FixtureContext()) { context in
                preparedPath = context.targetAppBundle?.fileURL
                throw FixtureFailure(message: "pipeline-failed")
            }
        }
        try require(preparedPath != nil && !fm.fileExists(atPath: preparedPath!.path), "Actual defer cleans pipeline failure")
    }
    try await record("integration_pipeline_cancellation_cleans_copy") {
        var preparedPath: URL?
        var cancelled = false
        do {
            try await runIntegration(operation: .refresh(installed), context: FixtureContext()) { context in
                preparedPath = context.targetAppBundle?.fileURL
                throw CancellationError()
            }
        } catch is CancellationError { cancelled = true }
        try require(cancelled && preparedPath != nil && !fm.fileExists(atPath: preparedPath!.path), "Actual defer cleans and preserves pipeline cancellation")
    }
    // Actual runner consumer and actual registry: original payload lacks nonce.
    let ordinaryID = "com.fixture.reuse." + UUID().uuidString
    let ordinaryURL = root.appendingPathComponent("Ordinary.app")
    try writeBundle(ordinaryURL, id: ordinaryID)
    let ordinary = InstalledApp(fileURL: ordinaryURL, bundleIdentifier: ordinaryID,
        resignedBundleIdentifier: ordinaryID + ".TEAM", appExtensions: [])
    let generation = UUID().uuidString
    let ordinaryBundle = ALTApplication(fileURL: ordinaryURL)!
    defer { V3ValidatedReuseMainRegistry.didAcknowledgeInstall(nil, original: ordinaryID,
        resigned: ordinary.resignedBundleIdentifier) }
    try await record("integration_legacy_bool_does_not_enroll_validated_strategy") {
        try await runIntegration(operation: .refresh(ordinary), context: FixtureContext()) { context in
            try require(context.useMainProfile && !context.validatedReuseMain, "Legacy bool remains legacy")
            try require(context.acknowledgedReuseMainIdentity == nil, "No fabricated install history")
        }
    }
    V3ValidatedReuseMainRegistry.didInstall(original: ordinaryID,
        resigned: ordinary.resignedBundleIdentifier, profileUUID: ordinaryBundle.provisioningProfile?.uuid,
        generation: generation)
    try await record("integration_old_registry_does_not_migrate_implicitly") {
        try await runIntegration(operation: .refresh(ordinary), context: FixtureContext()) { context in
            try require(!context.validatedReuseMain && context.acknowledgedReuseMainIdentity == nil, "V1 is not live proof")
        }
    }
    let acknowledgedIdentity = V3ValidatedReuseMainRegistry.AcknowledgedIdentity(original: ordinaryID,
        resigned: ordinary.resignedBundleIdentifier, sourceFingerprint: ordinary.appBundleFingerprint!,
        sourceDigest: AppBundleFingerprint.compute(for: ordinaryURL)!, profileUUID: UUID(), generation: generation,
        teamID: "TEAM", certificateDER: Data([1, 2]), extensionIdentities: [:], reusedExtensionIdentifiers: [])
    V3ValidatedReuseMainRegistry.didAcknowledgeInstall(acknowledgedIdentity, original: ordinaryID,
        resigned: ordinary.resignedBundleIdentifier)
    try await record("integration_ack_history_recovered_from_nonce_free_source") {
        try require(ordinaryBundle.infoPlist[V3ValidatedReuseMainRegistry.generationKey] == nil, "Original source has no signed nonce")
        try await runIntegration(operation: .refresh(ordinary), context: FixtureContext()) { context in
            try require(context.acknowledgedReuseMainIdentity == acknowledgedIdentity, "Consumer reads acknowledged output history")
            try require(!context.validatedReuseMain, "History is not live installed-state proof")
        }
    }
    try await record("integration_opt_out_bool_excludes_ack_history") {
        ordinary.useMainProfile = false
        defer { ordinary.useMainProfile = true }
        try await runIntegration(operation: .refresh(ordinary), context: FixtureContext()) { context in
            try require(!context.validatedReuseMain && context.acknowledgedReuseMainIdentity == nil, "Opt-out excludes reuse evidence")
        }
    }
    try ordinaryBundle.updateInfoPlist(with: ["FixtureSourceChange": "different"])
    try await record("integration_changed_source_is_unknown_not_replacement") {
        try await runIntegration(operation: .refresh(ordinary), context: FixtureContext()) { context in
            try require(context.acknowledgedReuseMainIdentity == nil && !context.validatedReuseMain, "Source drift invalidates history without reinstall instruction")
        }
    }
    try await record("all_terminal_paths_preserve_source_and_cleanup") {
        try require(noOwnedCopies(temp), "No request-owned scratch survives")
        try require(AppBundleFingerprint.compute(for: source) == before, "Source unchanged after all cases")
    }
    return cases
}
do {
    let cases = try await runFixture()
    let report: [String: Any] = ["schema": "v3-host-refresh-bundle-runtime-v1", "pass": true,
        "cases": cases, "case_count": cases.count, "network_executed": false,
        "provider_executed": false, "device_executed": false]
    print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
} catch {
    fputs("Synthetic host refresh bundle fixture failed: \(error)\n", stderr)
    exit(1)
}
