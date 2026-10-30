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

// Fixed local observations only. No profile, certificate, bundle ID or provider text.
struct V3RefreshSelectionFailure: Error, Sendable {
    enum Reason: String, CaseIterable, Sendable {
        case missingRefreshProfiles, missingTargetAppBundle, missingInstalledRecord
        case missingMainProfile, missingVerifiedCertificate, extensionOutsideParent
        case mainProfileIdentityMismatch, mainProfileExpired, mainProfileCertificateMismatch
        case extensionProfileIdentityMismatch, extensionProfileExpired, extensionProfileCertificateMismatch
        case extensionTeamMismatch, legacyProofUnavailable, legacyHostProofUnavailable
        case missingExtensionProfile, unexpectedProfileKeys, inconsistentProfileUUID, unexpectedProfileUUID
    }
    enum Scope: String, Sendable { case host, nonHost, unknown }
    let reason: Reason
    let scope: Scope
    var facts: [String: String] {
        ["refresh_failure_kind": "invalidParameters", "local_precondition": reason.rawValue,
         "refresh_target_scope": scope.rawValue]
    }
}

final class RefreshAppOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    
    // Set before execution; only refresh pipelines supply this owned admission.
    var refreshAdmission: (() throws -> Void)?
    var verificationNow: () -> Date = Date.init

    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[RefreshAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[RefreshAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        guard let profiles = self.context.provisioningProfiles else {
            throw selectionFailure(.missingRefreshProfiles)
        }
        
        guard let appBundle = self.context.targetAppBundle else {
            throw selectionFailure(.missingTargetAppBundle)
        }
        let dbContext = self.context.dbBackgroundContext
        let selection = try await dbContext.perform { try self.selectProfiles(profiles, in: dbContext) }
        let before = await self.readProfilesWithoutMutation()
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
        
        do {
            await CellularRefreshManager.shared.turnOffDataIfNeeded()
            // V3_REFRESH_PROFILE_ADMISSION_V1: the cellular await may expire the
            // owner. Check once before first injection, never between injected
            // profiles or before recording the resulting database state.
            try refreshAdmission?()
            let admissionDate = verificationNow()
            guard selection.certificateExpiry > admissionDate,
                  selection.profiles.allSatisfy({ $0.expirationDate > admissionDate }) else {
                throw OperationError.invalidParameters("The selected signing lifetime expired before installation began.")
            }
            let dispatched = V3RefreshVerification(installAcknowledged: false)
            context.refreshVerification = dispatched
            context.recordRefreshVerification?(dispatched)
            for p in profiles {
                try await installProvisioningProfiles(p.value.data)
            }
            // Acknowledged means ALL required injections returned success. A
            // partial batch remains dispatched/unconfirmed; it cannot be replayed.
            let acknowledged = V3RefreshVerification()
            context.refreshVerification = acknowledged
            context.recordRefreshVerification?(acknowledged)
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
        } catch {
            await CellularRefreshManager.shared.turnOnDataIfNeeded()
            throw V3RefreshFailureBoundary.provisioningProfileInstallation.preserving(error)
        }
        
        self.setProgress(80)
        let after = await self.readProfilesWithoutMutation()
        let verification = V3RefreshVerification.evaluate(expected: selection.profiles,
            before: before, after: after, certificateSerial: selection.certificateSerial,
            certificateExpiry: selection.certificateExpiry, certificateData: selection.certificateData, now: verificationNow())
        self.context.refreshVerification = verification
        self.context.recordRefreshVerification?(verification)
        // No cancellation check after injection: durable accounting must still run.
        let installedApp: InstalledApp
        do {
            installedApp = try await dbContext.perform {
                try self.updateInstalledApp(for: appBundle, profiles: profiles, in: dbContext)
            }
        } catch {
            throw V3RefreshFailureBoundary.refreshRecordUpdate.preserving(error)
        }
        
        self.setProgress(100)
        return installedApp
    }
    
    private func readProfilesWithoutMutation() async -> [ALTProvisioningProfile]? {
        await V3RefreshVerification.readProfiles(context.readInstalledProvisioningProfiles)
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

    private func updateInstalledApp(for appBundle: ALTApplication, profiles: [String: ALTProvisioningProfile], in dbContext: NSManagedObjectContext) throws -> InstalledApp {
        self.setProgress(self.progress.completedUnitCount + 1)
        
        guard let mainApp = self.context.installedApp,
              let installedApp = dbContext.object(with: mainApp.objectID) as? InstalledApp else {
            throw OperationError.invalidParameters("Could not find installed database record for '\(appBundle.name)'")
        }
        guard let mainProfile = profiles[self.context.targetBundleIdentifier] else {
            throw OperationError.invalidParameters("The main provisioning profile is missing.")
        }
        installedApp.update(provisioningProfile: mainProfile)
        
        if let certStatus = self.context.targetCertStatus {
            installedApp.certificateStatus = certStatus
        }

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
    var wire: [String: Any] {
        ["version": 1, "mutationDispatched": mutationDispatched, "installAcknowledged": installAcknowledged, "profileStore": profileStore.rawValue,
         "renewal": renewal.rawValue, "certificate": certificate]
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
