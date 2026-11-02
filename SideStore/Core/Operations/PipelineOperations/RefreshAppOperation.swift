//
//  RefreshAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 2/27/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
import SideSign
import Minimuxer

// Fixed local observations only. No profile, certificate, bundle ID or provider text.
struct V3RefreshSelectionFailure: Error, Sendable {
    enum Reason: String, CaseIterable, Sendable {
        case missingRefreshProfiles, missingTargetAppBundle, missingInstalledRecord
        case missingMainProfile, missingVerifiedCertificate, extensionOutsideParent
        case mainProfileIdentityMismatch, mainProfileExpired, mainProfileCertificateMismatch
        case extensionProfileIdentityMismatch, extensionProfileExpired, extensionProfileCertificateMismatch
        case extensionTeamMismatch, legacyProofUnavailable, legacyHostProofUnavailable
        case missingExtensionProfile, unexpectedProfileKeys, inconsistentProfileUUID, unexpectedProfileUUID
        case preservationEvidenceUnavailable, preservationIdentityUnavailable, preservationAuthorityConflict
        case preservationAuthorizationChanged, preservationExpiredCertificate, preservationNotExtended
        case preservationSnapshotChanged, preservationPortalIdentityUnavailable, preservationMalformedProfile, preservationUUIDConflict
    }
    enum Scope: String, Sendable { case host, nonHost, unknown }
    let reason: Reason
    let scope: Scope
    let preservationConflict: String?
    let cmsSignerDiagnostic: String?
    let appleProfileOrigin: String?
    init(reason: Reason, scope: Scope, preservationConflict: String? = nil, cmsSignerDiagnostic: String? = nil,
         appleProfileOrigin: String? = nil) {
        self.reason = reason; self.scope = scope; self.preservationConflict = preservationConflict
        self.cmsSignerDiagnostic = cmsSignerDiagnostic
        self.appleProfileOrigin = appleProfileOrigin
    }
    // This producer is also extracted independently of the wire model. Validate
    // here AND at the receiving boundary; never forward arbitrary error text.
    static func validCMSSignerDiagnostic(_ value: String) -> Bool {
        guard value.utf8.count <= 200 else { return false }
        let fields = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9, fields[0] == "cs1",
              ["installed", "candidate", "freshInstalled", "freshCandidate"].contains(fields[1]),
              fields[2...6].allSatisfy({ ["unchecked", "passed", "failed"].contains($0) }),
              fields[6] == "failed" else { return false }
        let verified = fields[2...5].allSatisfy { $0 == "passed" }
        if !verified { return fields[7] == "unchecked" && fields[8] == "unknown" }
        guard fields[7].utf8.count == 4, fields[7].utf8.allSatisfy({ $0 == 48 || $0 == 49 }) else { return false }
        return fields[8] == "unknown" || (fields[8].utf8.count == 64 && fields[8].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    }
    static let appleProfileOriginKinds: Set<String> = ["requestUnavailable", "recordNotFound", "ambiguousRecord",
        "responseMismatch", "invalidResponse", "responseTooLarge", "operationCancelled", "operationExpired", "ownershipChanged"]
    var facts: [String: String] {
        var result = ["refresh_failure_kind": "invalidParameters", "local_precondition": reason.rawValue,
                      "refresh_target_scope": scope.rawValue]
        if reason == .preservationEvidenceUnavailable, scope == .nonHost,
           let origin = appleProfileOrigin, origin.utf8.count <= 32, Self.appleProfileOriginKinds.contains(origin) {
            result["apple_profile_origin"] = origin
        }
        if reason == .preservationAuthorityConflict, scope == .nonHost,
           let detail = preservationConflict,
           ["multipleIdentities", "alternateIdentity", "teamMismatch", "prefixMismatch", "signerMissing",
            "entitlementsDiffer", "certificatesDiffer", "devicesDiffer", "platformsDiffer",
            "embeddedDERDiffer", "displayMetadataDiffer", "otherAuthorityDiffer",
            "embeddedDERUnsupportedSigner", "embeddedDERSignerTimeInvalid", "embeddedDERVerificationFailed",
            "embeddedDERUnsupportedRepresentation", "embeddedDERBindingMismatch"].contains(detail) {
            result["preservation_conflict"] = detail
            if detail == "embeddedDERUnsupportedSigner", let diagnostic = cmsSignerDiagnostic,
               Self.validCMSSignerDiagnostic(diagnostic) {
                result["cms_signer_diagnostic"] = diagnostic
            }
        }
        return result
    }
}

// An acknowledged profile injection is not a verified renewal. This is a
// terminal, post-dispatch outcome: callers must not retry or imply rollback.
// Only fixed local text is exposed; native errors and profile data stay private.
enum V3PreservationPostDispatchFailure: LocalizedError, Sendable {
    case verificationUnavailable
    case verificationMismatch

    var errorDescription: String? {
        switch self {
        case .verificationUnavailable:
            return "The profile installation was acknowledged, but renewal could not be verified. Review the device before trying again."
        case .verificationMismatch:
            return "The profile installation was acknowledged, but the profile inventory did not verify. Review the device before trying again."
        }
    }

    static func outcome(for verification: V3RefreshVerification) -> Self? {
        if verification.installAcknowledged && verification.profileStore == .matched &&
            verification.renewal == .extended && verification.certificate == "valid" &&
            verification.preservation == "authorizationPreserved" { return nil }
        return verification.profileStore == .unavailable ? .verificationUnavailable : .verificationMismatch
    }
}

final class RefreshAppOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    
    // Set before execution; only refresh pipelines supply this owned admission.
    var refreshAdmission: (() throws -> Void)?
    var verificationNow: () -> Date = Date.init

    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { context.preservationRefreshState?.origin.operation.invalidate() }
        debugLog("[RefreshAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[RefreshAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        guard let profiles = self.context.provisioningProfiles else {
            throw selectionFailure(.missingRefreshProfiles)
        }
        
        guard self.context.isPreservationRefresh || self.context.targetAppBundle != nil else {
            throw selectionFailure(.missingTargetAppBundle)
        }
        let dbContext = self.context.dbBackgroundContext
        let selection = try await dbContext.perform { try self.selectProfiles(profiles, in: dbContext) }
        var before = await self.readProfilesWithoutMutation()
        try refreshAdmission?()
        self.setProgress(10)
        
        if self.context.isCellularRefreshGroup {
            debugLog("[RefreshAppOperation] Queueing app for batch profile injection.")
            self.context.sharedContext.addPendingProfileBatch(PendingProfileBatch(
                bundleID: self.context.bundleIdentifier,
                profiles: profiles.values.map { $0.data },
                app: self.context.installedApp,
                certStatus: self.context.targetCertStatus
            ))
            self.setProgress(85)
            guard let app = self.context.installedApp else {
                throw OperationError.invalidParameters("RefreshAppOperation: context.installedApp is nil")
            }
            return app
        }
        
        var preservationMutationDispatched = false
        do {
            await CellularRefreshManager.shared.turnOffDataIfNeeded()
            // V3_REFRESH_PROFILE_ADMISSION_V1: the cellular await may expire the
            // owner. Check once before first injection, never between injected
            // profiles or before recording the resulting database state.
            try refreshAdmission?()
            if context.isPreservationRefresh {
                before = try await validateFreshPreservationSnapshot(profiles)
                // Rebind the database target after readback suspension as well.
                _ = try await dbContext.perform { try self.selectProfiles(profiles, in: dbContext) }
                try refreshAdmission?()
                // Recheck provenance lifetime after the final database await.
                try context.preservationRefreshState?.validateOriginAdmission()
            }
            let admissionDate = verificationNow()
            guard selection.certificateExpiry > admissionDate,
                  selection.profiles.allSatisfy({ $0.expirationDate > admissionDate }) else {
                throw OperationError.invalidParameters("The selected signing lifetime expired before installation began.")
            }
            preservationMutationDispatched = true
            let dispatched = V3RefreshVerification(installAcknowledged: false)
            context.refreshVerification = dispatched
            context.recordRefreshVerification?(dispatched)
            for p in profiles {
                if context.isPreservationRefresh {
                    try await installPreservationProvisioningProfile(p.value.data)
                } else {
                    try await installProvisioningProfiles(p.value.data)
                }
            }
            // Acknowledged means ALL required injections returned success. A
            // partial batch remains dispatched/unconfirmed; it cannot be replayed.
            let acknowledged = V3RefreshVerification()
            context.refreshVerification = acknowledged
            context.recordRefreshVerification?(acknowledged)
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
        } catch let selection as V3RefreshSelectionFailure where context.isPreservationRefresh && !preservationMutationDispatched {
            // Retain only typed, finite pre-dispatch preservation guards. Actual
            // injection/ACK failures retain their installation boundary unchanged.
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
            throw selection
        } catch {
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
            // An error after dispatch can be a lost acknowledgement. Do not
            // inject again or infer the device state. The current native profile
            // read has no bounded cancellation guarantee, so do not start an
            // unbounded reconciliation read while holding the transaction.
            throw V3RefreshFailureBoundary.provisioningProfileInstallation.preserving(error)
        }
        
        self.setProgress(80)
        let after = await self.readProfilesWithoutMutation()
        var verification = V3RefreshVerification.evaluate(expected: selection.profiles,
            before: before, after: after, certificateSerial: selection.certificateSerial,
            certificateExpiry: selection.certificateExpiry, certificateData: selection.certificateData, now: verificationNow())
        if context.isPreservationRefresh {
            if context.preservationRefreshState?.validatePostReadback(after) == true,
               verification.profileStore == .matched, verification.renewal == .extended,
               verification.certificate == "valid" {
                verification.preservation = "authorizationPreserved"
            } else {
                verification.profileStore = after == nil ? .unavailable : .mismatch
                verification.renewal = .unknown
                verification.certificate = "unknown"
                verification.preservation = nil
            }
        }
        self.context.refreshVerification = verification
        self.context.recordRefreshVerification?(verification)
        // No cancellation check after injection: durable accounting must still run.
        let installedApp: InstalledApp
        do {
            installedApp = try await dbContext.perform {
                try self.updateInstalledApp(profiles: profiles, in: dbContext)
            }
        } catch {
            throw V3RefreshFailureBoundary.refreshRecordUpdate.preserving(error)
        }

        // Keep the recorded post-dispatch observation available to all result
        // consumers, but never return a success for an unverified preservation
        // refresh. updateInstalledApp deliberately left expiry unchanged above.
        if context.isPreservationRefresh,
           let failure = V3PreservationPostDispatchFailure.outcome(for: verification) {
            throw failure
        }
        
        self.setProgress(100)
        return installedApp
    }
    
    private func validateFreshPreservationSnapshot(_ profiles: [String: ALTProvisioningProfile]) async throws -> [ALTProvisioningProfile] {
        guard let state = context.preservationRefreshState,
              let read = context.readInstalledProvisioningProfiles,
              profiles.count == 1, profiles[context.targetBundleIdentifier]?.data == state.candidateData else {
            throw selectionFailure(.preservationEvidenceUnavailable)
        }
        try refreshAdmission?()
        let bytes: [Data]
        do { bytes = try await read() }
        catch {
            if error is CancellationError { throw error }
            throw selectionFailure(.preservationEvidenceUnavailable)
        }
        try refreshAdmission?()
        do {
            try state.validateFresh(bytes, now: verificationNow(), admission: refreshAdmission)
            return try bytes.map { try ALTProvisioningProfile(data: $0) }
        } catch let failure as V3RefreshSelectionFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch { throw V3PreservationRefreshState.map(error) }
    }

    private func readProfilesWithoutMutation() async -> [ALTProvisioningProfile]? {
        if context.isPreservationRefresh {
            guard let read = context.readInstalledProvisioningProfiles else { return nil }
            do {
                let bytes = try await read()
                try V3PreservationRefreshState.checkInventoryBounds(bytes)
                return try bytes.map { try ALTProvisioningProfile(data: $0) }
            } catch { return nil }
        }
        return await V3RefreshVerification.readProfiles(context.readInstalledProvisioningProfiles)
    }

    private struct ProfileSelection {
        let profiles: [ALTProvisioningProfile]
        let certificateSerial: String
        let certificateExpiry: Date
        let certificateData: Data
    }

    private func selectionFailure(_ reason: V3RefreshSelectionFailure.Reason) -> V3RefreshSelectionFailure {
        let scope: V3RefreshSelectionFailure.Scope
        // The immutable operation identity avoids reading a managed object off
        // its queue when an early context guard fails.
        let originalID = context.bundleIdentifier
        scope = originalID.isEmpty ? .unknown : (originalID == StoreApp.altstoreAppID ? .host : .nonHost)
        debugLog("[V3_REFRESH_SELECTION] guard=\(reason.rawValue) scope=\(scope.rawValue)")
        return V3RefreshSelectionFailure(reason: reason, scope: scope)
    }

    private func extensionProfileKey(_ ext: InstalledExtension, main: InstalledApp) throws -> String {
        let originalParent = main.bundleIdentifier
        guard ext.bundleIdentifier.hasPrefix(originalParent + ".") else {
            throw selectionFailure(.extensionOutsideParent)
        }
        return context.targetBundleIdentifier + ext.bundleIdentifier.dropFirst(originalParent.count)
    }

    // Legacy self installs may sign each extension with the host application-id
    // while keeping a distinct CFBundleIdentifier. Prove that exact relationship
    // from the currently installed owner, never from cached/staged metadata.
    private func installedHostAuthorizesLegacyReuse(_ ext: InstalledExtension, main app: InstalledApp,
                                                   profile: ALTProvisioningProfile,
                                                   certificate: (serial: String, data: Data, expiry: Date)) -> Bool {
        let ownerURL = Bundle.Info.activeBundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard app.bundleIdentifier == StoreApp.altstoreAppID,
              app.resignedBundleIdentifier == Bundle.Info.activeBundleIdentifier,
              let owner = ALTApplication(fileURL: ownerURL),
              owner.bundleIdentifier == app.resignedBundleIdentifier,
              let signedMainID = owner.entitlements[ALTEntitlement.applicationIdentifier] as? String,
              signedMainID.hasSuffix("." + app.resignedBundleIdentifier),
              signedMainID.count > app.resignedBundleIdentifier.count + 1,
              let allowedMainID = profile.entitlements[ALTEntitlement.applicationIdentifier] as? String,
              signedMainID == allowedMainID || (allowedMainID.hasSuffix(".*") && signedMainID.hasPrefix(String(allowedMainID.dropLast()))),
              owner.entitlements[ALTEntitlement(rawValue: "com.apple.developer.team-identifier")] as? String == profile.teamIdentifier else { return false }
        let extensions = owner.appExtensions.filter { $0.bundleIdentifier == ext.resignedBundleIdentifier }
        guard extensions.count == 1, let installed = extensions.first else { return false }
        let pluginURL = installed.fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard pluginURL.pathExtension == "appex",
              pluginURL.deletingLastPathComponent() == ownerURL.appendingPathComponent("PlugIns"),
              installed.entitlements[ALTEntitlement.applicationIdentifier] as? String == signedMainID,
              installed.entitlements[ALTEntitlement(rawValue: "com.apple.developer.team-identifier")] as? String == profile.teamIdentifier,
              let embedded = installed.provisioningProfile,
              embedded.teamIdentifier == profile.teamIdentifier,
              embedded.bundleIdentifier == app.resignedBundleIdentifier,
              embedded.certificates.contains(where: { $0.serialNumber == certificate.serial && $0.data == certificate.data }),
              let signedCertificate = CertificateManager.shared.getSigningCertificate(at: pluginURL),
              signedCertificate.serialNumber == certificate.serial,
              signedCertificate.data == certificate.data else { return false }
        return true
    }

    private func selectProfiles(_ profiles: [String: ALTProvisioningProfile], in db: NSManagedObjectContext) throws -> ProfileSelection {
        guard let original = context.installedApp,
              let app = db.object(with: original.objectID) as? InstalledApp else {
            throw selectionFailure(.missingInstalledRecord)
        }
        guard let main = profiles[context.targetBundleIdentifier] else {
            throw selectionFailure(.missingMainProfile)
        }
        guard let certificate = context.verifiedRefreshCertificate, !certificate.data.isEmpty else {
            throw selectionFailure(.missingVerifiedCertificate)
        }
        if context.isPreservationRefresh {
            guard let state = context.preservationRefreshState,
                  !context.isCellularRefreshGroup, context.legacyReplacementBinding == nil,
                  app.useMainProfile, app.bundleIdentifier == context.bundleIdentifier,
                  app.bundleIdentifier != StoreApp.altstoreAppID,
                  app.resignedBundleIdentifier == state.baseline.binding.resignedBundleID,
                  !certificate.serial.isEmpty,
                  (app.certificateSerialNumber == nil || app.certificateSerialNumber == certificate.serial),
                  app.team == nil || app.team?.identifier == state.baseline.binding.teamID,
                  certificate.data == state.baseline.binding.historicalSignerDER,
                  certificate.expiry == state.baseline.binding.certificateExpiration,
                  profiles.count == 1, main.data == state.candidateData else {
                throw selectionFailure(.preservationIdentityUnavailable)
            }
            if let history = context.acknowledgedReuseMainIdentity {
                guard history.original == app.bundleIdentifier, history.resigned == app.resignedBundleIdentifier,
                      history.teamID == state.baseline.binding.teamID, history.certificateDER == certificate.data else {
                    throw selectionFailure(.preservationIdentityUnavailable)
                }
            }
            return ProfileSelection(profiles: [main], certificateSerial: certificate.serial,
                                    certificateExpiry: certificate.expiry, certificateData: certificate.data)
        }
        func authorizationFailure(_ profile: ALTProvisioningProfile, signedID: String, extensionProfile: Bool) -> V3RefreshSelectionFailure.Reason? {
            let pattern = profile.bundleIdentifier
            guard !signedID.isEmpty && (pattern == signedID ||
                (pattern.hasSuffix(".*") && signedID.hasPrefix(String(pattern.dropLast()))) || pattern == "*") else {
                return extensionProfile ? .extensionProfileIdentityMismatch : .mainProfileIdentityMismatch
            }
            guard profile.expirationDate > verificationNow() else {
                return extensionProfile ? .extensionProfileExpired : .mainProfileExpired
            }
            guard !certificate.serial.isEmpty,
                  profile.certificates.contains(where: { $0.serialNumber == certificate.serial && $0.data == certificate.data }) else {
                return extensionProfile ? .extensionProfileCertificateMismatch : .mainProfileCertificateMismatch
            }
            return nil
        }
        func authorizes(_ profile: ALTProvisioningProfile, signedID: String) -> Bool {
            authorizationFailure(profile, signedID: signedID, extensionProfile: true) == nil
        }
        if let reason = authorizationFailure(main, signedID: app.resignedBundleIdentifier, extensionProfile: false) {
            throw selectionFailure(reason)
        }
        var selected = [main]
        var allowedKeys: Set<String> = [context.targetBundleIdentifier]
        for ext in app.appExtensions {
            let key = try extensionProfileKey(ext, main: app)
            if let profile = profiles[key] {
                allowedKeys.insert(key)
                if let reason = authorizationFailure(profile, signedID: ext.resignedBundleIdentifier, extensionProfile: true) {
                    throw selectionFailure(reason)
                }
                guard profile.teamIdentifier == main.teamIdentifier else {
                    throw selectionFailure(.extensionTeamMismatch)
                }
                selected.append(profile)
            } else if context.useMainProfile {
                // Preserve explicit existing main-profile reuse; do not infer it
                // from a missing extension profile or an arbitrary dictionary value.
                guard authorizes(main, signedID: ext.resignedBundleIdentifier) ||
                    installedHostAuthorizesLegacyReuse(ext, main: app, profile: main, certificate: certificate) ||
                    (context.validatedReuseMain && context.previouslyReusedExtensionIdentifiers.contains(ext.resignedBundleIdentifier) &&
                     ext.resignedBundleIdentifier.hasPrefix(app.resignedBundleIdentifier + ".")) else {
                    throw selectionFailure(app.bundleIdentifier == StoreApp.altstoreAppID ? .legacyHostProofUnavailable : .legacyProofUnavailable)
                }
                selected.append(main)
            } else {
                throw selectionFailure(.missingExtensionProfile)
            }
        }
        // Keep each inference step small for the supported Swift compiler. The
        // UUID groups must still contain identical data, identity and team.
        let profileGroups = Dictionary(grouping: Array(profiles.values), by: { $0.uuid })
        var duplicateUUIDsAreConsistent = true
        for group in profileGroups.values {
            guard let first = group.first else { continue }
            for profile in group {
                if profile.data != first.data || profile.bundleIdentifier != first.bundleIdentifier ||
                    profile.teamIdentifier != first.teamIdentifier {
                    duplicateUUIDsAreConsistent = false
                }
            }
        }
        let suppliedUUIDs = Set(profiles.values.map { $0.uuid })
        let selectedUUIDs = Set(selected.map { $0.uuid })
        guard Set(profiles.keys) == allowedKeys else { throw selectionFailure(.unexpectedProfileKeys) }
        guard duplicateUUIDsAreConsistent else { throw selectionFailure(.inconsistentProfileUUID) }
        guard suppliedUUIDs == selectedUUIDs else { throw selectionFailure(.unexpectedProfileUUID) }
        return ProfileSelection(profiles: selected, certificateSerial: certificate.serial,
                                certificateExpiry: certificate.expiry, certificateData: certificate.data)
    }

    private func updateInstalledApp(profiles: [String: ALTProvisioningProfile], in dbContext: NSManagedObjectContext) throws -> InstalledApp {
        self.setProgress(self.progress.completedUnitCount + 1)
        
        guard let mainApp = self.context.installedApp,
              let installedApp = dbContext.object(with: mainApp.objectID) as? InstalledApp else {
            throw selectionFailure(.missingInstalledRecord)
        }
        guard let mainProfile = profiles[self.context.targetBundleIdentifier] else {
            throw OperationError.invalidParameters("The main provisioning profile is missing.")
        }
        if context.isPreservationRefresh {
            // Do not advertise an expiry that readback did not confirm. Even a
            // confirmed store renewal is not proof of installed extension launch.
            guard let observed = context.refreshVerification,
                  observed.profileStore == .matched, observed.renewal == .extended,
                  observed.certificate == "valid" else { return installedApp }
        }
        installedApp.update(provisioningProfile: mainProfile)
        
        if let certStatus = self.context.targetCertStatus {
            installedApp.certificateStatus = certStatus
        }

        // Profile-store renewal does not assert which profile each installed
        // extension uses. Leave its historical identity/lifetime untouched.
        if context.isPreservationRefresh { return installedApp }
        for installedExtension in installedApp.appExtensions {
            let key = try extensionProfileKey(installedExtension, main: installedApp)
            guard let provisioningProfile = profiles[key] ?? (context.useMainProfile ? mainProfile : nil) else {
                throw OperationError.invalidParameters("An extension provisioning profile is missing.")
            }
            installedExtension.update(provisioningProfile: provisioningProfile)
        }
        return installedApp
    }
}

// V3_REFRESH_VERIFICATION_V1: acknowledged mutation is not proof of renewal.
// Only these finite, non-secret values cross the service boundary.
struct V3RefreshVerification: Sendable {
    enum ProfileStore: String, Sendable { case matched, mismatch, unavailable }
    enum Renewal: String, Sendable { case extended, unchanged, shortened, unknown }
    var profileStore: ProfileStore = .unavailable
    var renewal: Renewal = .unknown
    var certificate = "unknown"
    var installAcknowledged = true
    var mutationDispatched = true
    var preservation: String?
    var wire: [String: Any] {
        var result: [String: Any] = ["version": 1, "mutationDispatched": mutationDispatched, "installAcknowledged": installAcknowledged, "profileStore": profileStore.rawValue,
         "renewal": renewal.rawValue, "certificate": certificate]
        if preservation == "authorizationPreserved" { result["preservation"] = preservation }
        return result
    }

    static func readProfiles(_ read: (() async throws -> [Data])?) async -> [ALTProvisioningProfile]? {
        guard let read else { return nil }
        do { return try await read().map { try ALTProvisioningProfile(data: $0) } }
        catch { return nil } // Never publish raw native/profile errors or bytes.
    }

    static func authorizes(_ profile: ALTProvisioningProfile, signedID: String,
                           certificateSerial: String, certificateData: Data, now: Date) -> Bool {
        let pattern = profile.bundleIdentifier
        let identity = !signedID.isEmpty && (pattern == signedID ||
            (pattern.hasSuffix(".*") && signedID.hasPrefix(String(pattern.dropLast()))) || pattern == "*")
        return identity && !certificateSerial.isEmpty && profile.expirationDate > now &&
            profile.certificates.contains { $0.serialNumber == certificateSerial && $0.data == certificateData }
    }

    static func evaluate(expected: [ALTProvisioningProfile], before: [ALTProvisioningProfile]?,
                         after: [ALTProvisioningProfile]?, certificateSerial: String,
                         certificateExpiry: Date, certificateData: Data, now: Date = Date()) -> Self {
        var result = Self()
        result.certificate = certificateExpiry > now ? "valid" : "invalid"
        guard !expected.isEmpty, let after else { return result }
        let expectedGroups = Dictionary(grouping: expected, by: \.uuid)
        guard expectedGroups.values.allSatisfy({ group in
            group.allSatisfy { $0.data == group[0].data }
        }), expected.allSatisfy({ $0.expirationDate > now &&
            $0.certificates.contains { $0.serialNumber == certificateSerial && $0.data == certificateData } }) else {
            result.profileStore = .mismatch
            return result
        }
        guard expected.allSatisfy({ wanted in
            let sameUUID = after.filter { $0.uuid == wanted.uuid }
            return sameUUID.count == 1 && sameUUID[0].data == wanted.data &&
                sameUUID[0].bundleIdentifier == wanted.bundleIdentifier &&
                sameUUID[0].teamIdentifier == wanted.teamIdentifier &&
                sameUUID[0].expirationDate == wanted.expirationDate
        }) else {
            result.profileStore = .mismatch
            return result
        }
        result.profileStore = .matched
        guard let before, !certificateSerial.isEmpty else { return result }
        var priorExpirations: [Date] = []
        for wanted in expected {
            // Compare only profiles authorizing the same signed identity/team/certificate.
            // Multiple installed profiles are legitimate; use the greatest previous
            // lifetime so an older duplicate cannot manufacture an apparent renewal.
            let compatible = before.filter {
                $0.bundleIdentifier == wanted.bundleIdentifier && $0.teamIdentifier == wanted.teamIdentifier &&
                $0.certificates.contains { $0.serialNumber == certificateSerial && $0.data == certificateData }
            }
            guard let prior = compatible.map(\.expirationDate).max() else { return result }
            priorExpirations.append(prior)
        }
        guard let oldProfileExpiry = priorExpirations.min(),
              let newProfileExpiry = expected.map(\.expirationDate).min() else { return result }
        let oldEffective = min(oldProfileExpiry, certificateExpiry)
        let newEffective = min(newProfileExpiry, certificateExpiry)
        result.renewal = newEffective > oldEffective ? .extended : (newEffective == oldEffective ? .unchanged : .shortened)
        return result
    }
}

// V3_PRESERVATION_PROFILE_AUTHORIZATION_V1
import CoreFoundation

// Pure policy only. The adapter must supply COMPLETE decoded profile payloads
// from a fresh owned readback, never a projection or an unsigned source cache.
// This proves equal profile authorization, NOT installed-binary/extension linkage.
enum PreservedProfilePolicy {
    enum Failure: String, Error, Sendable {
        case missingHistoricalBinding, malformedProfile, missingInstalledProfile
        case conflictingInstalledAuthority, duplicateUUIDConflict, changedAuthorization
        case expiredCertificate, noEffectiveExtension
        // Diagnostic refinement only: all map to the existing public conflict.
        case multipleIdentities, alternateIdentity, teamMismatch, prefixMismatch, signerMissing
        case entitlementsDiffer, certificatesDiffer, devicesDiffer, platformsDiffer
        case embeddedDERDiffer, displayMetadataDiffer, otherAuthorityDiffer
        case embeddedDERUnsupportedSigner, embeddedDERSignerTimeInvalid, embeddedDERVerificationFailed
        case embeddedDERUnsupportedRepresentation, embeddedDERBindingMismatch
        var preservationConflict: String? {
            switch self {
            case .multipleIdentities, .alternateIdentity, .teamMismatch, .prefixMismatch, .signerMissing,
                 .entitlementsDiffer, .certificatesDiffer, .devicesDiffer, .platformsDiffer,
                 .embeddedDERDiffer, .displayMetadataDiffer, .otherAuthorityDiffer,
                 .embeddedDERUnsupportedSigner, .embeddedDERSignerTimeInvalid, .embeddedDERVerificationFailed,
                 .embeddedDERUnsupportedRepresentation, .embeddedDERBindingMismatch: return rawValue
            default: return nil
            }
        }
    }
    // A normalized comparison projection is not an authority credential. Only this
    // file constructs it after strict cryptographic/representation checks; candidate
    // authority is separately required through an exact Apple-origin receipt.
    struct ProfileInput {
        let raw: [String: Any]
        fileprivate let normalizedInnerAuthority: [String: Data]?
        init(raw: [String: Any]) { self.raw = raw; normalizedInnerAuthority = nil }
        fileprivate init(raw: [String: Any], normalizedConstraints: [String: Data]) {
            self.raw = raw; normalizedInnerAuthority = normalizedConstraints
        }
    }
    struct Binding: Equatable, Sendable {
        let resignedBundleID: String
        let applicationIdentifier: String // Exact prefix + ID; not synthesized from team.
        let teamID: String
        let historicalSignerDER: Data
        let certificateExpiration: Date
        let useMainProfile: Bool
    }
    struct Decision: Sendable {
        let priorUUIDs: [String]
        let priorEffectiveExpiration: Date
        let newEffectiveExpiration: Date
        // Deliberately no validatedReuseMain / extension-renewal claim.
    }
    indirect enum Value: Equatable, Sendable {
        case string(String), data(Data), date(Date), bool(Bool), number(String)
        case array([Value]), dictionary([String: Value])
        init(_ raw: Any) throws {
            switch raw {
            case let x as String: self = .string(x)
            case let x as Data: self = .data(x)
            case let x as Date: self = .date(x)
            case let x as NSNumber:
                if CFGetTypeID(x) == CFBooleanGetTypeID() { self = .bool(x.boolValue) }
                else {
                    guard x.doubleValue.isFinite else { throw Failure.malformedProfile }
                    self = .number(x.stringValue)
                }
            case let x as [Any]: self = .array(try x.map { try Value($0) })
            case let x as [String: Any]: self = .dictionary(try x.mapValues { try Value($0) })
            default: throw Failure.malformedProfile
            }
        }
    }
    struct Evidence: Equatable, Sendable {
        let binding: Binding
        let priorUUIDs: [String]
        let priorEffectiveExpiration: Date
        let authority: Value
        let installedPayloadsByUUID: [String: Value]
        func hasSameTarget(as other: Evidence) -> Bool {
            binding == other.binding && priorUUIDs == other.priorUUIDs &&
            priorEffectiveExpiration == other.priorEffectiveExpiration && authority == other.authority &&
            priorUUIDs.allSatisfy { installedPayloadsByUUID[$0] == other.installedPayloadsByUUID[$0] }
        }
    }
    private struct Profile {
        let uuid: String
        let applicationID: String
        let teamID: String
        let expiration: Date
        let certificates: [Data]
        let prefixes: [String]
        let authority: Value
        let complete: Value
        // Decode identity using the profile's declared App ID prefix, not an
        // arbitrary suffix. A different bundle may end with the target bundle ID.
        // Legacy App ID prefixes need not equal TeamIdentifier (Apple TN2318).
        func targetsBundle(_ bundleID: String) -> Bool {
            guard !applicationID.contains("*") else { return false }
            guard prefixes.count == 1, let prefix = prefixes.first,
                  !prefix.isEmpty, !prefix.contains("."), !prefix.contains("*"),
                  applicationID.hasPrefix(prefix + ".") else {
                // Preserve prior conservative handling of malformed/ambiguous
                // declarations: a possible target must still reach rejection,
                // never disappear from the authority checks as "unrelated".
                return applicationID.hasSuffix("." + bundleID) &&
                    applicationID.count > bundleID.count + 1
            }
            return String(applicationID.dropFirst(prefix.count + 1)) == bundleID
        }
        init(_ raw: [String: Any]) throws { try self.init(ProfileInput(raw: raw)) }
        init(_ input: ProfileInput) throws {
            let raw = input.raw
            guard let id = raw["UUID"] as? String, let parsed = UUID(uuidString: id),
                  let entitlements = raw["Entitlements"] as? [String: Any],
                  let appID = entitlements["application-identifier"] as? String, !appID.isEmpty,
                  let team = entitlements["com.apple.developer.team-identifier"] as? String, !team.isEmpty,
                  let teams = raw["TeamIdentifier"] as? [String], teams == [team],
                  let prefixes = raw["ApplicationIdentifierPrefix"] as? [String], !prefixes.isEmpty,
                  let expiry = raw["ExpirationDate"] as? Date,
                  let creation = raw["CreationDate"] as? Date, expiry > creation,
                  let certs = raw["DeveloperCertificates"] as? [Data], !certs.isEmpty,
                  certs.allSatisfy({ !$0.isEmpty }), Set(certs).count == certs.count else {
                throw Failure.malformedProfile
            }
            uuid = parsed.uuidString; applicationID = appID; teamID = team
            expiration = expiry; certificates = certs; self.prefixes = prefixes
            complete = try Value(raw)
            var authorization = raw
            // CMS envelope signature is outside this decoded payload. All unknown
            // payload fields remain compared, including Name, platforms, devices,
            // prefix arrays, every entitlement and certificate bytes. Array order
            // is conservatively preserved where ordering semantics are unverified;
            // this does not infer which keychain group an installed binary uses.
            for key in ["UUID", "CreationDate", "ExpirationDate", "TimeToLive"] {
                authorization.removeValue(forKey: key)
            }
            var compared = try authorization.mapValues { try Value($0) }
            if let inner = input.normalizedInnerAuthority {
                guard raw["DER-Encoded-Profile"] is Data else { throw Failure.embeddedDERUnsupportedRepresentation }
                compared["DER-Encoded-Profile"] = .dictionary(inner.mapValues { .data($0) })
            }
            authority = .dictionary(compared)
        }
    }
    static func selectSnapshot(resignedBundleID: String, teamID: String,
                               historicalSignerDER: Data, certificateExpiration: Date,
                               useMainProfile: Bool, installed: [[String: Any]], now: Date) throws -> Evidence {
        try selectSnapshot(resignedBundleID: resignedBundleID, teamID: teamID,
            historicalSignerDER: historicalSignerDER, certificateExpiration: certificateExpiration,
            useMainProfile: useMainProfile, inputs: installed.map { ProfileInput(raw: $0) }, now: now)
    }
    static func selectSnapshot(resignedBundleID: String, teamID: String,
                               historicalSignerDER: Data, certificateExpiration: Date,
                               useMainProfile: Bool, inputs: [ProfileInput], now: Date) throws -> Evidence {
        guard !resignedBundleID.isEmpty else { throw Failure.missingHistoricalBinding }
        let parsed = try inputs.map { try Profile($0) }
        let identities = Set(parsed.filter {
            $0.targetsBundle(resignedBundleID)
        }.map(\.applicationID))
        guard !identities.isEmpty else { throw Failure.missingInstalledProfile }
        guard identities.count == 1, let identity = identities.first else {
            throw Failure.multipleIdentities
        }
        return try snapshot(binding: Binding(resignedBundleID: resignedBundleID,
            applicationIdentifier: identity, teamID: teamID, historicalSignerDER: historicalSignerDER,
            certificateExpiration: certificateExpiration, useMainProfile: useMainProfile), inputs: inputs, now: now)
    }
    static func snapshot(binding: Binding, installed: [[String: Any]], now: Date) throws -> Evidence {
        try snapshot(binding: binding, inputs: installed.map { ProfileInput(raw: $0) }, now: now)
    }
    static func snapshot(binding: Binding, inputs: [ProfileInput], now: Date) throws -> Evidence {
        guard binding.useMainProfile, !binding.resignedBundleID.isEmpty,
              !binding.teamID.isEmpty, !binding.historicalSignerDER.isEmpty,
              binding.applicationIdentifier.hasSuffix("." + binding.resignedBundleID),
              binding.applicationIdentifier.count > binding.resignedBundleID.count + 1,
              !binding.applicationIdentifier.contains("*") else { throw Failure.missingHistoricalBinding }
        guard binding.certificateExpiration > now else { throw Failure.expiredCertificate }
        let all = try inputs.map { try Profile($0) }
        var byUUID: [String: Value] = [:]
        for profile in all {
            if let previous = byUUID[profile.uuid], previous != profile.complete {
                throw Failure.duplicateUUIDConflict
            }
            byUUID[profile.uuid] = profile.complete
        }
        // A new alternate prefix for this exact bundle identity is target drift,
        // not an unrelated application's inventory change.
        guard all.filter({ $0.targetsBundle(binding.resignedBundleID)
        }).allSatisfy({ $0.applicationID == binding.applicationIdentifier }) else {
            throw Failure.alternateIdentity
        }
        let old = all.filter { $0.applicationID == binding.applicationIdentifier }
        guard let first = old.first else { throw Failure.missingInstalledProfile }
        let exactPrefix = String(binding.applicationIdentifier.dropLast(binding.resignedBundleID.count + 1))
        // Same acceptance predicate, split only for finite privacy-safe diagnostics.
        // Fixed category precedence is independent of CopyAll inventory order.
        guard old.allSatisfy({ $0.teamID == binding.teamID }) else { throw Failure.teamMismatch }
        guard !exactPrefix.isEmpty, !exactPrefix.contains("."),
              old.allSatisfy({ $0.prefixes == [exactPrefix] }) else { throw Failure.prefixMismatch }
        guard old.allSatisfy({ $0.certificates.contains(binding.historicalSignerDER) }) else {
            throw Failure.signerMissing
        }
        guard old.allSatisfy({ $0.authority == first.authority }) else {
            // No field is excluded or normalized by this classification.
            // Even embedded DER and unknown fields remain part of strict equality.
            let categories: [([String], Failure)] = [
                (["Entitlements"], .entitlementsDiffer),
                (["DeveloperCertificates"], .certificatesDiffer),
                (["ProvisionedDevices", "ProvisionsAllDevices"], .devicesDiffer),
                (["Platform"], .platformsDiffer),
                (["DER-Encoded-Profile"], .embeddedDERDiffer),
                (["Name", "AppIDName", "TeamName"], .displayMetadataDiffer)
            ]
            for (keys, reason) in categories {
                guard case let .dictionary(reference) = first.authority else { continue }
                if old.contains(where: { profile in
                    guard case let .dictionary(value) = profile.authority else { return false }
                    return keys.contains { value[$0] != reference[$0] }
                }) { throw reason }
            }
            throw Failure.otherAuthorityDiffer
        }
        return Evidence(binding: binding, priorUUIDs: Array(Set(old.map(\.uuid))).sorted(),
            priorEffectiveExpiration: min(old.map(\.expiration).max()!, binding.certificateExpiration),
            authority: first.authority, installedPayloadsByUUID: byUUID)
    }
    static func validate(candidate: [String: Any], baseline: Evidence, now: Date) throws -> Decision {
        try validate(input: ProfileInput(raw: candidate), baseline: baseline, now: now)
    }
    static func validate(input: ProfileInput, baseline: Evidence, now: Date) throws -> Decision {
        let binding = baseline.binding
        guard binding.certificateExpiration > now else { throw Failure.expiredCertificate }
        let new = try Profile(input)
        if baseline.installedPayloadsByUUID[new.uuid] != nil {
            // Never overwrite any existing UUID, even if its decoded payload is identical.
            throw Failure.duplicateUUIDConflict
        }
        guard new.applicationID == binding.applicationIdentifier,
              new.teamID == binding.teamID,
              new.certificates.contains(binding.historicalSignerDER),
              new.authority == baseline.authority else { throw Failure.changedAuthorization }
        let prior = baseline.priorEffectiveExpiration
        let next = min(new.expiration, binding.certificateExpiration)
        guard next > now, next > prior else { throw Failure.noEffectiveExtension }
        return Decision(priorUUIDs: baseline.priorUUIDs,
                        priorEffectiveExpiration: prior, newEffectiveExpiration: next)
    }
    static func hasOnlyEmbeddedDERDifference(candidate: [String: Any], baseline: Evidence) throws -> Bool {
        let profile = try Profile(candidate)
        guard case let .dictionary(oldAuthority) = baseline.authority,
              case let .dictionary(newAuthority) = profile.authority,
              case let .data(oldDER)? = oldAuthority["DER-Encoded-Profile"],
              case let .data(newDER)? = newAuthority["DER-Encoded-Profile"],
              !oldDER.isEmpty, !newDER.isEmpty, oldDER != newDER else { return false }
        var old = oldAuthority, new = newAuthority
        old.removeValue(forKey: "DER-Encoded-Profile")
        new.removeValue(forKey: "DER-Encoded-Profile")
        return old == new
    }
    static func targetIndices(resignedBundleID: String, installed: [[String: Any]]) throws -> [Int] {
        let parsed = try installed.map { try Profile($0) }
        return parsed.indices.filter { parsed[$0].targetsBundle(resignedBundleID) }
    }
    // Raw target drift must be checked even when raw authority equality would
    // reject different embedded CMS signatures. No semantic-mode upgrade here.
    static func sameRawTarget(baseline: Evidence, installed: [[String: Any]]) throws -> Bool {
        let all = try installed.map { try Profile($0) }
        var complete: [String: Value] = [:]
        for profile in all {
            if let prior = complete[profile.uuid], prior != profile.complete { throw Failure.duplicateUUIDConflict }
            complete[profile.uuid] = profile.complete
        }
        let target = all.filter { $0.targetsBundle(baseline.binding.resignedBundleID) }
        guard target.allSatisfy({ $0.applicationID == baseline.binding.applicationIdentifier }),
              Array(Set(target.map(\.uuid))).sorted() == baseline.priorUUIDs else { return false }
        return baseline.priorUUIDs.allSatisfy { complete[$0] == baseline.installedPayloadsByUUID[$0] }
    }
    static func evaluate(binding: Binding, installed: [[String: Any]],
                         candidate: [String: Any], now: Date) throws -> Decision {
        try validate(candidate: candidate, baseline: snapshot(binding: binding, installed: installed, now: now), now: now)
    }
}

// Candidate authority comes only from a private SideSign Apple HTTPS receipt.
// Historical profiles below cannot confer authority on any signer or candidate.
struct V3AppleProfileOriginEvidence: Sendable {
    let operation: AppleProfileOperation
    let candidate: AppleProfileEvidence
    func authorizeCandidate(_ bytes: Data) throws {
        guard candidate.cmsData == bytes else {
            throw V3PreservationRefreshState.failure(.preservationEvidenceUnavailable)
        }
        try operation.authorize(candidate, exactCMS: bytes)
    }
}

/// Restrictive historical observations only. Not proof of signer role, installed
/// binary entitlements, launch, extension identity or Keychain accessibility.
struct HistoricalConstraintSnapshot: Sendable {
    let baseline: PreservedProfilePolicy.Evidence
    let originalInventory: [Data]
    let profilesByUUID: [UUID: Data]
}

struct V3PreservationRefreshState: Sendable {
    let historical: HistoricalConstraintSnapshot
    let candidateData: Data
    let origin: V3AppleProfileOriginEvidence
    var baseline: PreservedProfilePolicy.Evidence { historical.baseline }
    var originalInventory: [Data] { historical.originalInventory }
    struct Prepared: Sendable {
        let historical: HistoricalConstraintSnapshot
        var baseline: PreservedProfilePolicy.Evidence { historical.baseline }
        var originalInventory: [Data] { historical.originalInventory }
    }

    static func prepare(resignedBundleID: String, teamID: String, signerDER: Data,
                        certificateExpiration: Date, inventory: [Data], now: Date,
                        admission: (() throws -> Void)?) throws -> Prepared {
        let started = ProcessInfo.processInfo.systemUptime
        try checkInventoryBounds(inventory)
        try checkWork(admission, started: started)
        let raw = try payloads(inventory)
        let profilesByUUID = try exactProfilesByUUID(inventory)
        var inputs = raw.map { PreservedProfilePolicy.ProfileInput(raw: $0) }
        let indices = try PreservedProfilePolicy.targetIndices(resignedBundleID: resignedBundleID, installed: raw)
        for index in indices {
            try checkWork(admission, started: started)
            // The result constrains comparison only; no custom inner leaf role pin
            // and no old-profile portal lookup is an admission prerequisite.
            inputs[index] = try historicalConstraintInput(inventory[index], admission: admission, started: started)
            guard try PreservedProfilePolicy.Value(inputs[index].raw) == PreservedProfilePolicy.Value(raw[index]) else {
                throw PreservedProfilePolicy.Failure.embeddedDERBindingMismatch
            }
        }
        let baseline = try PreservedProfilePolicy.selectSnapshot(resignedBundleID: resignedBundleID,
            teamID: teamID, historicalSignerDER: signerDER, certificateExpiration: certificateExpiration,
            useMainProfile: true, inputs: inputs, now: now)
        try checkWork(admission, started: started)
        return Prepared(historical: HistoricalConstraintSnapshot(baseline: baseline,
            originalInventory: inventory, profilesByUUID: profilesByUUID))
    }

    static func finish(prepared: Prepared, candidateData: Data, now: Date,
                       admission: (() throws -> Void)?, origin: V3AppleProfileOriginEvidence? = nil) throws -> Self {
        guard let origin else { throw failure(.preservationEvidenceUnavailable) }
        let started = ProcessInfo.processInfo.systemUptime
        // The retained old inventory plus the new record must fit the same
        // bounded readback budget before any injection can be admitted.
        try checkInventoryBounds(prepared.originalInventory + [candidateData])
        try checkWork(admission, started: started)
        let candidate = try authenticatedCandidateInput(candidateData, origin: origin, admission: admission, started: started)
        let model = try ALTProvisioningProfile(data: candidateData)
        guard prepared.historical.profilesByUUID[model.uuid] == nil else {
            throw PreservedProfilePolicy.Failure.duplicateUUIDConflict
        }
        _ = try PreservedProfilePolicy.validate(input: candidate, baseline: prepared.baseline, now: now)
        try origin.authorizeCandidate(candidateData)
        try checkWork(admission, started: started)
        return Self(historical: prepared.historical, candidateData: candidateData, origin: origin)
    }

    func validateFresh(_ inventory: [Data], now: Date, admission: (() throws -> Void)?) throws {
        let started = ProcessInfo.processInfo.systemUptime
        try Self.checkInventoryBounds(inventory)
        try Self.checkWork(admission, started: started)
        // Preserve every old blob, not only target payload semantics. No repair,
        // mode upgrade, dropping an expired profile or automatic snapshot retry.
        guard Self.multiset(inventory) == Self.multiset(originalInventory) else {
            throw Self.failure(.preservationSnapshotChanged)
        }
        _ = try Self.exactProfilesByUUID(inventory)
        let candidate = try Self.authenticatedCandidateInput(candidateData, origin: origin, admission: admission, started: started)
        let model = try ALTProvisioningProfile(data: candidateData)
        guard historical.profilesByUUID[model.uuid] == nil else { throw PreservedProfilePolicy.Failure.duplicateUUIDConflict }
        _ = try PreservedProfilePolicy.validate(input: candidate, baseline: baseline, now: now)
        try origin.authorizeCandidate(candidateData)
        try Self.checkWork(admission, started: started)
    }

    /// Post-ACK observation only. Never triggers another injection or claims rollback.
    func validatePostReadback(_ after: [ALTProvisioningProfile]?) -> Bool {
        guard let after else { return false }
        do {
            let bytes = after.map(\.data)
            try Self.checkInventoryBounds(bytes)
            let byUUID = try Self.exactProfilesByUUID(bytes)
            let candidate = try ALTProvisioningProfile(data: candidateData)
            guard historical.profilesByUUID[candidate.uuid] == nil,
                  after.filter({ $0.uuid == candidate.uuid }).count == 1,
                  byUUID[candidate.uuid] == candidateData,
                  historical.profilesByUUID.allSatisfy({ byUUID[$0.key] == $0.value }) else { return false }
            // Only the intended additive change may qualify. Unexpected extra
            // target or unrelated records are uncertainty, never silent success.
            return Self.multiset(bytes) == Self.multiset(originalInventory + [candidateData])
        } catch { return false }
    }

    func validateOriginAdmission() throws {
        do { try origin.authorizeCandidate(candidateData) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Self.originFailure(error) }
    }
    private static func multiset(_ inventory: [Data]) -> [Data: Int] {
        inventory.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
    static func checkInventoryBounds(_ inventory: [Data]) throws {
        guard inventory.count <= 512 else { throw failure(.preservationEvidenceUnavailable) }
        var total = 0
        for bytes in inventory {
            let (next, overflow) = total.addingReportingOverflow(bytes.count)
            guard !overflow, !bytes.isEmpty, bytes.count <= 1_048_576, next <= 32 * 1024 * 1024 else {
                throw failure(.preservationEvidenceUnavailable)
            }
            total = next
        }
    }
    private static func exactProfilesByUUID(_ inventory: [Data]) throws -> [UUID: Data] {
        var result: [UUID: Data] = [:]
        for bytes in inventory {
            let profile = try ALTProvisioningProfile(data: bytes)
            if let previous = result[profile.uuid], previous != bytes {
                throw PreservedProfilePolicy.Failure.duplicateUUIDConflict
            }
            result[profile.uuid] = bytes
        }
        return result
    }
    private static func checkWork(_ admission: (() throws -> Void)?, started: TimeInterval) throws {
        try Task.checkCancellation()
        try admission?()
        guard ProcessInfo.processInfo.systemUptime - started <= 20 else {
            throw failure(.preservationEvidenceUnavailable)
        }
    }
    private static func historicalConstraintInput(_ bytes: Data, admission: (() throws -> Void)?,
                                                  started: TimeInterval) throws -> PreservedProfilePolicy.ProfileInput {
        try normalizedComparisonInput(bytes, admission: admission, started: started)
    }
    private static func authenticatedCandidateInput(_ bytes: Data, origin: V3AppleProfileOriginEvidence,
        admission: (() throws -> Void)?, started: TimeInterval) throws -> PreservedProfilePolicy.ProfileInput {
        try checkWork(admission, started: started)
        try origin.authorizeCandidate(bytes)
        let input = try normalizedComparisonInput(bytes, admission: admission, started: started)
        // Inspection is NOT provenance. Exact independently authorized candidate
        // bytes must remain operation/account-owned after all cryptographic work.
        try origin.authorizeCandidate(bytes)
        try checkWork(admission, started: started)
        return input
    }
    private static func normalizedComparisonInput(_ bytes: Data, admission: (() throws -> Void)?,
                                                  started: TimeInterval) throws -> PreservedProfilePolicy.ProfileInput {
        do {
            try checkWork(admission, started: started)
            let outerXML = try ProfileCMSVerifier.authenticateOuter(bytes)
            let outer = try PreservedProfileDecoder.decodeOuter(verifiedOuterXML: outerXML)
            // Preserve supported XML-only profiles only when DER is genuinely
            // absent. Malformed/present DER can never select this branch.
            if !outer.keys.contains("DER-Encoded-Profile") {
                guard try PreservedProfilePolicy.Value(outer) == PreservedProfilePolicy.Value(payloads([bytes])[0]) else {
                    throw PreservedProfilePolicy.Failure.embeddedDERBindingMismatch
                }
                try checkWork(admission, started: started)
                return PreservedProfilePolicy.ProfileInput(raw: outer)
            }
            guard let nestedCMS = outer["DER-Encoded-Profile"] as? Data, !nestedCMS.isEmpty else {
                throw PreservedProfilePolicy.Failure.embeddedDERUnsupportedRepresentation
            }
            let innerDER = try ProfileCMSVerifier.inspectInnerCryptography(nestedCMS).untrustedContent
            try checkWork(admission, started: started)
            let decoded = try PreservedProfileDecoder.decode(verifiedOuterXML: outerXML, verifiedInnerDER: innerDER)
            guard try PreservedProfilePolicy.Value(decoded.rawOuter) == PreservedProfilePolicy.Value(payloads([bytes])[0]) else {
                throw PreservedProfilePolicy.Failure.embeddedDERBindingMismatch
            }
            try checkWork(admission, started: started)
            return PreservedProfilePolicy.ProfileInput(raw: decoded.rawOuter,
                normalizedConstraints: decoded.normalizedInnerAuthority)
        } catch let error as ProfileCMSVerificationError {
            switch error {
            case .unsupportedSigner: throw PreservedProfilePolicy.Failure.embeddedDERUnsupportedSigner
            case .signerTimeInvalid: throw PreservedProfilePolicy.Failure.embeddedDERSignerTimeInvalid
            case .verificationFailed: throw PreservedProfilePolicy.Failure.embeddedDERVerificationFailed
            case .unsupportedRepresentation: throw PreservedProfilePolicy.Failure.embeddedDERUnsupportedRepresentation
            }
        } catch let error as PreservedProfileDecoder.Failure {
            switch error {
            case .inconsistent: throw PreservedProfilePolicy.Failure.embeddedDERBindingMismatch
            case .malformed, .unsupported: throw PreservedProfilePolicy.Failure.embeddedDERUnsupportedRepresentation
            }
        }
    }

    static func payloads(_ profiles: [Data]) throws -> [[String: Any]] {
        try profiles.map { data in
            try ALTProvisioningProfile(data: data).propertyList().mapValues { $0 as Any }
        }
    }

    static func failure(_ reason: V3RefreshSelectionFailure.Reason) -> V3RefreshSelectionFailure {
        V3RefreshSelectionFailure(reason: reason, scope: .nonHost)
    }

    static func originFailure(_ error: Error) -> V3RefreshSelectionFailure {
        let token: String
        switch error as? AppleProfileEvidenceError {
        case .recordNotFound: token = "recordNotFound"
        case .ambiguousProfile: token = "ambiguousRecord"
        case .identityMismatch: token = "responseMismatch"
        case .invalidResponse: token = "invalidResponse"
        case .responseTooLarge: token = "responseTooLarge"
        case .cancelled: token = "operationCancelled"
        case .expiredOperation: token = "operationExpired"
        case .ownershipChanged: token = "ownershipChanged"
        case .unavailable, nil: token = "requestUnavailable"
        }
        return V3RefreshSelectionFailure(reason: .preservationEvidenceUnavailable, scope: .nonHost,
            appleProfileOrigin: token)
    }

    static func map(_ error: Error) -> V3RefreshSelectionFailure {
        if let existing = error as? V3RefreshSelectionFailure { return existing }
        if error is AppleProfileEvidenceError { return originFailure(error) }
        let reason: V3RefreshSelectionFailure.Reason
        switch error as? PreservedProfilePolicy.Failure {
        case .missingHistoricalBinding: reason = .preservationIdentityUnavailable
        case .missingInstalledProfile: reason = .preservationEvidenceUnavailable
        case .malformedProfile: reason = .preservationMalformedProfile
        case .conflictingInstalledAuthority, .multipleIdentities, .alternateIdentity,
             .teamMismatch, .prefixMismatch, .signerMissing, .entitlementsDiffer,
             .certificatesDiffer, .devicesDiffer, .platformsDiffer, .embeddedDERDiffer,
             .displayMetadataDiffer, .otherAuthorityDiffer,
             .embeddedDERUnsupportedSigner, .embeddedDERSignerTimeInvalid, .embeddedDERVerificationFailed,
             .embeddedDERUnsupportedRepresentation, .embeddedDERBindingMismatch: reason = .preservationAuthorityConflict
        case .duplicateUUIDConflict: reason = .preservationUUIDConflict
        case .changedAuthorization: reason = .preservationAuthorizationChanged
        case .expiredCertificate: reason = .preservationExpiredCertificate
        case .noEffectiveExtension: reason = .preservationNotExtended
        case nil: reason = .preservationMalformedProfile
        }
        return V3RefreshSelectionFailure(reason: reason, scope: .nonHost,
            preservationConflict: (error as? PreservedProfilePolicy.Failure)?.preservationConflict)
    }
}
