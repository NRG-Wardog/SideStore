//
//  FetchProvisioningProfilesOperation.swift
//  AltStore
//
//  Created by Riley Testut on 2/27/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import SideSign
import CoreData

class FetchProvisioningProfilesOperation: BasePipelineOperation<InstallAppOperationContext, [String: ALTProvisioningProfile]>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> [String: ALTProvisioningProfile] {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[FetchProvisioningProfilesOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[FetchProvisioningProfilesOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        if let error = self.context.error {
            self.debugLog("[FetchProvisioningProfiles] Context has a pre-existing error.")
            throw error
        }

        guard let targetAppBundle = self.context.targetAppBundle else {
            self.debugLog("[FetchProvisioningProfiles] Target app bundle missing in context.")
            throw OperationError.invalidParameters("FetchProvisioningProfilesOperation: context.targetAppBundle is nil")
        }

        try await self.context.validateLegacyReplacementAdmission()
        try self.context.validateLegacyReplacementBundle(targetAppBundle, signed: false)
        let effectiveBundleId = self.context.targetBundleIdentifier

        let appExtensions = targetAppBundle.appExtensions
        if self.context.validatedReuseMain &&
            (targetAppBundle.isAltStoreApp || targetAppBundle.bundleIdentifier == Bundle.Info.activeBundleIdentifier ||
             self.context.bundleIdentifier == StoreApp.altstoreAppID) {
            throw OperationError.invalidParameters("Experimental ReuseMain is not available for host self-install or self-refresh. Keep the existing signing strategy for the host.")
        }
        self.context.validateExtensionSigningCapabilities = self.context.validatedReuseMain || self.context.legacyReplacementBinding != nil
        self.context.originalExtensionBundleIdentifiers = [:]
        self.context.previouslyReusedExtensionIdentifiers = []

        if let overrideProfile = self.context.overrideProvisioningProfile {
            self.debugLog("[FetchProvisioningProfiles] Using override provisioning profile.")
            if self.context.validatedReuseMain {
                let reasons = try await reuseMainRejectionReasons(app: targetAppBundle, profile: overrideProfile)
                guard reasons.isEmpty else {
                    throw OperationError.invalidParameters("The override profile cannot safely use ReuseMain: " + reasons.joined(separator: ", ") + ". Select separate provisioning profiles instead.")
                }
            }
            var profiles = [effectiveBundleId: overrideProfile]
            if !self.context.useMainProfile, !appExtensions.isEmpty {
                for appExtension in appExtensions {
                    let updatedExtensionBundleId: String
                    if self.context.legacyReplacementBinding != nil {
                        updatedExtensionBundleId = try self.context.legacyReplacementProfileKey(originalID: appExtension.bundleIdentifier)
                    } else {
                        updatedExtensionBundleId = appExtension.bundleIdentifier.replacingOccurrences(of: targetAppBundle.bundleIdentifier, with: effectiveBundleId)
                    }
                    profiles[updatedExtensionBundleId] = overrideProfile
                }
            }
            self.setProgress(100)
            self.debugLog("[FetchProvisioningProfiles] Total override profiles prepared: \(profiles.count)")
            try self.context.validateLegacyReplacementProfiles(profiles)
            return profiles
        }

        let team = try await AuthManager.shared.getAuthenticatedTeam()
        try await self.context.validateLegacyReplacementAdmission()
        if let binding = self.context.legacyReplacementBinding {
            guard team.identifier == binding.teamID else {
                throw OperationError.invalidParameters("The replacement team changed.")
            }
            try await self.context.validateLegacyReplacementAdmission()
            let appIDs = try await DeveloperPortalProxy.shared.fetchAppIDs(for: team)
            try await self.context.validateLegacyReplacementAdmission()
            let desired = Set([binding.resignedBundleID] + Array(binding.extensionIdentities.values))
            let missing = desired.subtracting(Set(appIDs.map { $0.bundleIdentifier }))
            guard team.type != .free || missing.count <= max(0, Team.maximumFreeAppIDs - appIDs.count) else {
                throw OperationError.invalidParameters("Separate replacement profiles exceed the available App ID quota.")
            }
        }
        self.debugLog("[FetchProvisioningProfiles] Executing profile preparation; useMainProfile: \(self.context.useMainProfile)")
        
        self.setProgress(10)

        self.debugLog("[FetchProvisioningProfiles] Preparing main provisioning profile...")
        let profile = try await self.provisionAndFetchProfile(for: targetAppBundle, parentAppBundle: nil, team: team)
        self.debugLog("[FetchProvisioningProfiles] Main profile prepared successfully.")
        
        var profiles = [effectiveBundleId: profile]

        if self.context.validatedReuseMain, !appExtensions.isEmpty {
            let reasons = try await reuseMainRejectionReasons(app: targetAppBundle, profile: profile)
            if !reasons.isEmpty {
                // Decide before registering extension App IDs. A fallback keeps
                // all extensions and never silently drops their capabilities.
                guard try await self.context.handler.extensionRemovalHandler.confirmSeparateExtensionProvisioning(
                    reasonCodes: reasons, extensionReasonCodes: reuseMainRejectionDetails, extensionCount: appExtensions.count) else {
                    throw OperationError.cancelled
                }
                try Task.checkCancellation()
                self.context.useMainProfile = false
            }
        }

        guard !self.context.useMainProfile, !appExtensions.isEmpty else {
            self.setProgress(100)
            self.debugLog("[FetchProvisioningProfiles] Total profiles prepared: \(profiles.count)")
            try self.context.validateLegacyReplacementProfiles(profiles)
            return profiles
        }
        
        self.setProgress(50)
        self.debugLog("[FetchProvisioningProfiles] Preparing profiles for \(appExtensions.count) app extensions...")
        try await withThrowingTaskGroup(of: (String, ALTProvisioningProfile).self) { group in
            for appExtension in appExtensions {
                group.addTask {
                    self.verboseLog("[FetchProvisioningProfiles] Preparing extension profile...")
                    let extProfile = try await self.provisionAndFetchProfile(for: appExtension, parentAppBundle: targetAppBundle, team: team)
                    // Use customized bundle ID if applicable
                    let updatedExtensionBundleId: String
                    if self.context.legacyReplacementBinding != nil {
                        updatedExtensionBundleId = try self.context.legacyReplacementProfileKey(originalID: appExtension.bundleIdentifier)
                    } else {
                        updatedExtensionBundleId = appExtension.bundleIdentifier.replacingOccurrences(of: targetAppBundle.bundleIdentifier, with: effectiveBundleId)
                    }
                    self.verboseLog("[FetchProvisioningProfiles] Extension profile prepared.")
                    return (updatedExtensionBundleId, extProfile)
                }
            }
            
            var completedCount = 0
            let totalExtensions = appExtensions.count
            let startProgress = self.progress.completedUnitCount
            let endProgress: Int64 = 100
            let range = endProgress - startProgress
            
            for try await (bundleId, extProfile) in group {
                profiles[bundleId] = extProfile
                self.debugLog("[FetchProvisioningProfiles] Added extension profile.")
                completedCount += 1
                if range > 0 {
                    let percent = startProgress + Int64(Double(completedCount) / Double(totalExtensions) * Double(range))
                    self.setProgress(percent)
                }
            }
        }
        
        self.debugLog("[FetchProvisioningProfiles] Total profiles prepared: \(profiles.count)")
        try await self.context.validateLegacyReplacementAdmission()
        try self.context.validateLegacyReplacementProfiles(profiles)
        return profiles
    }


    // Explanation metadata only; the existing aggregate rejection and group
    // fallback decisions remain unchanged.
    private var reuseMainRejectionDetails: [String: [String]] = [:]

    private func reuseMainRejectionReasons(app: ALTApplication, profile: ALTProvisioningProfile) async throws -> [String] {
        reuseMainRejectionDetails = [:]
        func rejectAll(_ reason: String) -> [String] {
            for ext in app.appExtensions { reuseMainRejectionDetails[ext.bundleIdentifier] = [reason] }
            return [reason]
        }
        guard profile.expirationDate > Date() else { return rejectAll("mainProfileExpired") }
        guard self.context.customEntitlementsByBundleID.isEmpty else { return rejectAll("customEntitlementOverridesRequireSeparateProfiles") }
        let mainEntitlements = try ALTSigner.signingEntitlements(profile: profile, applicationEntitlements: app.entitlements)
        let hasPersistedAssociation = await self.context.dbBackgroundContext.perform {
            guard let installed = self.context.installedApp else { return false }
            return installed.useMainProfile && installed.bundleIdentifier == self.context.bundleIdentifier &&
                installed.resignedBundleIdentifier == app.bundleIdentifier &&
                installed.resignedBundleIdentifier == profile.bundleIdentifier
        }
        var reasons = Set<String>()
        for ext in app.appExtensions {
            guard ext.bundleIdentifier.hasPrefix(app.bundleIdentifier + ".") else {
                reuseMainRejectionDetails[ext.bundleIdentifier] = ["extensionIdentifierOutsideContainer"]
                reasons.insert("extensionIdentifierOutsideContainer")
                continue
            }
            let signedExtensionID = profile.bundleIdentifier + ext.bundleIdentifier.dropFirst(app.bundleIdentifier.count)
            self.context.originalExtensionBundleIdentifiers[signedExtensionID] = ext.bundleIdentifier
            let previousProfileMatches = hasPersistedAssociation && app.provisioningProfile != nil &&
                ext.provisioningProfile?.data == app.provisioningProfile?.data
            if previousProfileMatches { self.context.previouslyReusedExtensionIdentifiers.insert(signedExtensionID) }
            let decision = ExtensionSigningPolicy.evaluate(strategy: .reuseMainWhenCompatible,
                mainBundleIdentifier: profile.bundleIdentifier,
                extensionBundleIdentifier: signedExtensionID,
                mainEntitlements: mainEntitlements, extensionEntitlements: ext.entitlements,
                originalExtensionBundleIdentifier: ext.bundleIdentifier,
                allowPreviouslyReusedMainIdentity: previousProfileMatches)
            if !decision.reuseMain {
                reuseMainRejectionDetails[ext.bundleIdentifier] = decision.reasons
                reasons.formUnion(decision.reasons)
            }
        }
        return reasons.sorted()
    }

    private func getPreferredBundleID(for targetAppBundle: ALTApplication, team: ALTTeam) async -> String? {
        await DatabaseManager.shared.persistentContainer.performBackgroundTask { [weak self] (context) -> String? in
            guard let self else { return nil }
            let target = self.context.targetBundleIdentifier
            let predicate = NSPredicate(
                format: "(%K == %@) OR (%K == %@)",
                #keyPath(InstalledApp.customBundleIdentifier), target,
                #keyPath(InstalledApp.resignedBundleIdentifier), target
            )
            guard let installedApp = InstalledApp.first(satisfying: predicate, in: context) else {
                self.verboseLog("[FetchProvisioningProfiles] No existing InstalledApp found for target.")
                return nil
            }
            
            // Teams match if installedApp.team has same identifier as team (or team is nil)
            // AND installedApp.resignedBundleIdentifier actually contains the team's identifier.
            let teamsMatch = (installedApp.team?.identifier == team.identifier || installedApp.team == nil)
                             && installedApp.resignedBundleIdentifier.contains(team.identifier)
            
            self.verboseLog("[FetchProvisioningProfiles] Preferred bundle ID checked; teamsMatch=\(teamsMatch)")

            // TODO: @mahee96: Try to keep the debug build and release build operations similar, refactor later with proper reasoning
            //                 for now, restricted it to debug on simulator only
            #if DEBUG && targetEnvironment(simulator)

            let result = teamsMatch ? installedApp.resignedBundleIdentifier : nil
            self.debugLog("[FetchProvisioningProfiles] Preferred bundle ID resolved (DEBUG simulator): \(result != nil)")
            return result

            #else
            
            let result = teamsMatch ? installedApp.resignedBundleIdentifier : nil
            self.debugLog("[FetchProvisioningProfiles] Preferred bundle ID resolved: \(result != nil)")
            return result
            
            #endif
        }
    }
    
    private func provisionAndFetchProfile(for targetAppBundle: ALTApplication,
                                          parentAppBundle: ALTApplication?,
                                          team: ALTTeam) async throws -> ALTProvisioningProfile {
        // LC_PROVISIONING_PARENT_ID_UPSTREAM_V1
        let preferredBundleID = await self.getPreferredBundleID(for: targetAppBundle, team: team)
        let parentID: String
        if let preferredBundleID {
            parentID = preferredBundleID
        } else if self.context.appendTeamID {
            parentID = "\(self.context.targetBundleIdentifier).\(team.identifier)"
        } else {
            parentID = self.context.targetBundleIdentifier
        }

        let bundleID: String
        if let binding = self.context.legacyReplacementBinding {
            try await self.context.validateLegacyReplacementAdmission()
            guard team.identifier == binding.teamID,
                  let exactID = parentAppBundle == nil ? (targetAppBundle.bundleIdentifier == binding.originalBundleID ? binding.resignedBundleID : nil) : binding.extensionIdentities[targetAppBundle.bundleIdentifier] else {
                throw OperationError.invalidParameters("The replacement profile identity is not in the confirmed selection.")
            }
            bundleID = exactID
        } else if let parentAppBundle {
            guard targetAppBundle.bundleIdentifier.hasPrefix(parentAppBundle.bundleIdentifier + ".") else {
                throw OperationError.invalidApp(reason: "Extension bundle ID does not start with its parent bundle ID.")
            }
            let suffix = String(targetAppBundle.bundleIdentifier.dropFirst(parentAppBundle.bundleIdentifier.count))
            bundleID = parentID + suffix
        } else {
            bundleID = parentID
        }

        return try await lcProvisioningBundleRequest(
            role: parentAppBundle == nil ? "main" : "extension",
            originalBundleID: targetAppBundle.bundleIdentifier,
            preferredParentMatch: preferredBundleID != nil
        ) {
        let preferredName: String
        
        if let parentAppBundle = parentAppBundle {
            preferredName = parentAppBundle.name + " " + targetAppBundle.name
        } else {
            preferredName = targetAppBundle.name
        }
        
        self.debugLog("[FetchProvisioningProfiles] Registering App ID...")
        let appID = try await self.registerAppID(for: targetAppBundle, name: preferredName, bundleIdentifier: bundleID, team: team)
        try await self.context.validateLegacyReplacementAdmission()
        if self.context.legacyReplacementBinding != nil, appID.bundleIdentifier != bundleID {
            throw OperationError.invalidParameters("The replacement portal identity changed.")
        }
        self.debugLog("[FetchProvisioningProfiles] App ID registered successfully.")
        
        self.debugLog("[FetchProvisioningProfiles] Updating App ID features...")
        let updatedAppID = try await self.updateFeatures(for: appID, targetAppBundle: targetAppBundle, team: team)
        try await self.context.validateLegacyReplacementAdmission()
        if self.context.legacyReplacementBinding != nil, updatedAppID.bundleIdentifier != bundleID {
            throw OperationError.invalidParameters("The replacement portal identity changed.")
        }
        
        self.debugLog("[FetchProvisioningProfiles] Updating App ID groups...")
        let groupAppID = try await self.updateAppGroups(for: updatedAppID, targetAppBundle: targetAppBundle, team: team)
        try await self.context.validateLegacyReplacementAdmission()
        if self.context.legacyReplacementBinding != nil, groupAppID.bundleIdentifier != bundleID {
            throw OperationError.invalidParameters("The replacement portal identity changed.")
        }
        
        self.debugLog("[FetchProvisioningProfiles] Fetching provisioning profile from Apple...")
        try await self.context.validateLegacyReplacementAdmission()
        let profile = try await DeveloperPortalProxy.shared.downloadProvisioningProfile(for: groupAppID, deviceType: DeveloperPortalProxy.currentDeviceType, team: team)
        self.debugLog("[FetchProvisioningProfiles] Provisioning profile fetched.")
        try await self.context.validateLegacyReplacementAdmission()
        if let binding = self.context.legacyReplacementBinding {
            guard profile.bundleIdentifier == bundleID, profile.teamIdentifier == binding.teamID,
                  profile.certificates.contains(where: { $0.serialNumber == binding.certificateSerial && $0.data == binding.certificateDER }),
                  profile.expirationDate > Date() else {
                throw OperationError.invalidParameters("The returned replacement profile changed identity.")
            }
        }
        return profile
        }
    }
}


private extension FetchProvisioningProfilesOperation{
        
    func registerAppID(for targetAppBundle: ALTApplication,
                               name: String,
                               bundleIdentifier: String,
                               team: ALTTeam) async throws -> ALTAppID {
        let appIDs = try await V3RemoteRequestLeases.coalesce(key: "fetch_app_ids_\(team.identifier)") {
            if let cachedAppIDs = self.context.sharedContext.appIDs {
                self.debugLog("[FetchProvisioningProfiles] Using cached App IDs from shared context.")
                return cachedAppIDs
            }
            self.debugLog("[FetchProvisioningProfiles] Fetching existing App IDs from Apple...")
            try await self.context.validateLegacyReplacementAdmission()
            let fetchedAppIDs = try await DeveloperPortalProxy.shared.fetchAppIDs(for: team)
            self.context.sharedContext.appIDs = fetchedAppIDs
            self.verboseLog("[FetchProvisioningProfiles] Found \(fetchedAppIDs.count) existing App IDs on portal.")
            return fetchedAppIDs
        }
        
        if let appID = appIDs.first(where: { $0.bundleIdentifier.lowercased() == bundleIdentifier.lowercased() }) {
            self.debugLog("[FetchProvisioningProfiles] Found existing App ID on portal.")
            return appID
        } else {
            let requiredAppIDs = 1 + targetAppBundle.appExtensions.count
            let availableAppIDs = max(0, Team.maximumFreeAppIDs - appIDs.count)
            self.verboseLog("[FetchProvisioningProfiles] App ID not found on portal. Required: \(requiredAppIDs), Available: \(availableAppIDs)")
            
            let sortedExpirationDates = appIDs.compactMap { $0.expirationDate }.sorted(by: { $0 < $1 })
            
            let appIDName = self.sanitizeAppIDName(name: name, bundleIdentifier: bundleIdentifier)
            
            self.debugLog("[FetchProvisioningProfiles] Requesting new App ID registration...")
            try await self.context.validateLegacyReplacementAdmission()
            let appID = try await DeveloperPortalProxy.shared.addAppID(name: appIDName, bundleIdentifier: bundleIdentifier, team: team)
            self.context.sharedContext.appendAppID(appID)
            self.debugLog("[FetchProvisioningProfiles] Successfully registered new App ID on Apple portal.")
            return appID
        }
    }
    
    func updateFeatures(for appID: ALTAppID, targetAppBundle: ALTApplication, team: ALTTeam) async throws -> ALTAppID {
        let bundleID = targetAppBundle.bundleIdentifier
        var entitlements = self.context.customEntitlementsByBundleID[bundleID]
            ?? targetAppBundle.entitlements
        for (key, value) in context.additionalEntitlements {
            entitlements[key] = value
        }
        
        guard let allowedFeatures = team.type.allowedFeatures else {
            throw OperationError.invalidParameters("Cannot update features for unknown team type.")
        }
        
        var targetFeatures: [ALTFeature: String] = [:]
        var droppedFeatures: Set<ALTFeature> = []
        
        // Filter applicable features
        for (key, value) in entitlements {
            guard let feature = ALTFeature(entitlement: ALTEntitlement(rawValue: key)) else { 
                continue 
            }
            let isEnabled = (value as? [Any])?.isEmpty == false || (value as? Bool) ?? true
            
            if allowedFeatures.contains(feature) {
                targetFeatures[feature] = isEnabled ? "true" : "false"
            } else {
                droppedFeatures.insert(feature)
            }
        }
        
        // Force apply mandatory features
        for feature in AppConstants.mandatoryFeatures {
            if allowedFeatures.contains(feature) {
                targetFeatures[feature] = "true"
            } else {
                droppedFeatures.insert(feature)
            }
        }
        
        if !droppedFeatures.isEmpty {
            self.debugLog("[FetchProvisioningProfiles] Dropped \(droppedFeatures.count) non-applicable features.")
        }
        
        // check if we really need to make a update on portal
        let currentFeatures = appID.features
        let needsUpdate = targetFeatures.contains { feature, targetValue in
            // if not available yet assume feature = off
            let currentValue = currentFeatures[feature] ?? "false"
            return currentValue != targetValue
        }
        guard needsUpdate else { 
            self.debugLog("[FetchProvisioningProfiles] App ID features are already satisfied. Skipping portal update.")
            return appID 
        }
        
        // set for requesting and send request
        var appID = appID
        appID.features = targetFeatures
        
        do {
            try await self.context.validateLegacyReplacementAdmission()
            let updated = try await DeveloperPortalProxy.shared.updateAppID(appID, team: team)
            self.verboseLog("[FetchProvisioningProfiles] Updated App ID features.")
            return updated
        } catch {
            self.debugLog("[FetchProvisioningProfiles] Failed to update App ID features.")
            throw error
        }
    }
    
    func updateAppGroups(for appID: ALTAppID, targetAppBundle: ALTApplication, team: ALTTeam) async throws -> ALTAppID {
        let bundleID = targetAppBundle.bundleIdentifier
        var entitlements = self.context.customEntitlementsByBundleID[bundleID]
            ?? targetAppBundle.entitlements
        for (key, value) in self.context.additionalEntitlements {
            entitlements[key] = value
        }
                
        guard var applicationGroups = entitlements[ALTEntitlement.appGroups.rawValue] as? [String], !applicationGroups.isEmpty else {
            verboseLog("[FetchProvisioningProfiles] App ID has no app groups, skipping assignment.")
            // Assigning an App ID to an empty app group array fails,
            // so just do nothing if there are no app groups.
            return appID
        }
        
        for group in applicationGroups {
            if group.contains("$(APP_GROUP_IDENTIFIER)") {
                self.debugLog("[FetchProvisioningProfiles] Error: Application group contains an unresolved placeholder.")
                throw OperationError.invalidParameters("Application group '\(group)' contains raw placeholder '$(APP_GROUP_IDENTIFIER)'.")
            }
        }
        
        if targetAppBundle.isAltStoreApp {
            verboseLog("[FetchProvisioningProfiles] Application group count before modifying for SideStore: \(applicationGroups.count)")
            
            // Remove app groups that contain AltStore since they can be problematic (cause SideStore to expire early)
            for (index, group) in applicationGroups.enumerated() {
                if group.contains("AltStore") {
                    verboseLog("[FetchProvisioningProfiles] Removing application group.")
                    applicationGroups.remove(at: index)
                }
            }
            
            // Make sure we add .AltWidget for the widget
            var altStoreAppGroupID = Bundle.baseAltStoreAppGroupID
            for (_, group) in applicationGroups.enumerated() {
                if group.contains("AltWidget") {
                    altStoreAppGroupID += ".AltWidget"
                    break
                }
            }
            
            // Potentially updating app groups for this specific AltStore.
            // Find the (unique) AltStore app group, then replace it
            // with the correct "base" app group ID.
            // Otherwise, we may append a duplicate team identifier to the end.
            if let index = applicationGroups.firstIndex(where: { $0.contains(Bundle.baseAltStoreAppGroupID) }) {
                applicationGroups[index] = altStoreAppGroupID
            } else {
                applicationGroups.append(altStoreAppGroupID)
            }
        }
        verboseLog("[FetchProvisioningProfiles] Application group count: \(applicationGroups.count)")
        
        var seenGroupIDs = Set<String>()
        
        do {
            let appGroups = try await V3RemoteRequestLeases.coalesce(key: "fetch_app_groups_\(team.identifier)") {
                if let cachedGroups = self.context.sharedContext.appGroups {
                    self.debugLog("[FetchProvisioningProfiles] Using cached App Groups from shared context.")
                    return cachedGroups
                }
                self.debugLog("[FetchProvisioningProfiles] Fetching existing App Groups from Apple...")
                try await self.context.validateLegacyReplacementAdmission()
                let fetched = try await DeveloperPortalProxy.shared.fetchAppGroups(for: team)
                self.context.sharedContext.appGroups = fetched
                self.verboseLog("[FetchProvisioningProfiles] Found \(fetched.count) existing App Groups on portal.")
                return fetched
            }
            self.verboseLog("[FetchProvisioningProfiles] Active App Group count: \(appGroups.count)")
            
            var groups = [ALTAppGroup]()
            
            for groupIdentifier in applicationGroups {
                let adjustedGroupIdentifier = try await self.adjustedGroupIdentifier(for: groupIdentifier, appID: appID, targetAppBundle: targetAppBundle, team: team)
                guard seenGroupIDs.insert(adjustedGroupIdentifier).inserted else { continue }
                
                let group: ALTAppGroup
                if let existing = self.context.sharedContext.appGroups?.first(where: { $0.groupIdentifier == adjustedGroupIdentifier }) {
                    group = existing
                } else {
                    // Not all characters are allowed in group names, so we replace periods with spaces (like Apple does).
                    let name = "SideStore " + groupIdentifier.replacingOccurrences(of: ".", with: " ")
                    do {
                        group = try await V3RemoteRequestLeases.coalesce(key: "add_app_group_\(adjustedGroupIdentifier)") {
                            // skip add if already added into shared by other tasks
                            if let existing = self.context.sharedContext.appGroups?.first(where: { $0.groupIdentifier == adjustedGroupIdentifier }) {
                                return existing
                            }
                            try await self.context.validateLegacyReplacementAdmission()
                            let newGroup = try await DeveloperPortalProxy.shared.addAppGroup(name: name, groupIdentifier: adjustedGroupIdentifier, team: team)
                            self.context.sharedContext.appendAppGroup(newGroup)
                            self.verboseLog("[FetchProvisioningProfiles] Created new App Group.")
                            return newGroup
                        }
                    } catch {
                        self.debugLog("[FetchProvisioningProfiles] Failed to create new App Group.")
                        throw error
                    }
                }
                groups.append(group)
            }
            
            try await self.context.validateLegacyReplacementAdmission()
            try await DeveloperPortalProxy.shared.assignAppID(appID, to: Array(groups), team: team)
            let groupIDs = groups.map { $0.groupIdentifier }
            self.debugLog("[FetchProvisioningProfiles] Assigned App ID to \(groupIDs.count) App Groups.")
            
            return appID
        } catch {
            let groupIDs = Array(seenGroupIDs.isEmpty ? Set(applicationGroups.map { $0 + "." + team.identifier }) : seenGroupIDs)
            self.debugLog("[FetchProvisioningProfiles] Failed to assign or create App Groups.")
            throw error
        }
    }

    func adjustedGroupIdentifier(for groupIdentifier: String, appID: ALTAppID, targetAppBundle: ALTApplication, team: ALTTeam) async throws -> String {
        // Currently Build.xconfig for debug appends suffix as TEAMID already
        #if DEBUG
        if groupIdentifier.contains(Bundle.baseAltStoreAppGroupID) && groupIdentifier.contains(team.identifier) {
            return groupIdentifier
        }
        #endif

        let rawGroupID = groupIdentifier.hasPrefix("group.") ? String(groupIdentifier.dropFirst("group.".count)) : groupIdentifier
        let targetBundleID = targetAppBundle.bundleIdentifier
        let contextTargetBundleID = self.context.targetBundleIdentifier
        
        let matchesBundleID = rawGroupID.caseInsensitiveCompare(targetBundleID) == .orderedSame ||
                              rawGroupID.caseInsensitiveCompare(contextTargetBundleID) == .orderedSame
        let isExactCaseMatch = rawGroupID == targetBundleID || rawGroupID == contextTargetBundleID

        if matchesBundleID && !isExactCaseMatch {
            let correctedGroup = "group." + appID.bundleIdentifier
            let originalGroupWithTeam = groupIdentifier + "." + team.identifier
            
            if UserDefaults.standard.autoFixAppGroupIDs {
                return correctedGroup
            } else {
                let decision = try await self.context.handler.userCustomizationHandler.resolveAppGroupMismatch(
                    originalGroup: originalGroupWithTeam,
                    correctedGroup: correctedGroup
                )
                switch decision {
                case .correctAndProceed(let group):
                    return group
                case .keepOriginal(let group):
                    return group
                }
            }
        }

        return groupIdentifier + "." + team.identifier
    }
}

private extension FetchProvisioningProfilesOperation {
    func sanitizeAppIDName(name: String, bundleIdentifier: String) -> String {
        let sanitizedName = self.sanitizeToAscii(name)
        if !sanitizedName.isEmpty {
            return sanitizedName
        }

        return self.sanitizeToAscii(bundleIdentifier)
    }

    func sanitizeToAscii(_ string: String) -> String {
        let romanized = string.applyingTransform(.toLatin, reverse: false) ?? string

        let asciiConverted: String
        if let icuTransliterated = romanized.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) {
            asciiConverted = icuTransliterated
        } else if let lossyData = romanized.data(using: .ascii, allowLossyConversion: true),
                  let lossyString = String(data: lossyData, encoding: .ascii) {
            asciiConverted = lossyString
        } else {
            asciiConverted = romanized
        }

        var result = ""
        result.reserveCapacity(min(asciiConverted.utf8.count, 50))
        var lastWasSpace = true

        for scalar in asciiConverted.unicodeScalars {
            if result.count >= 50 { break }

            if (scalar.value >= 0x30 && scalar.value <= 0x39) ||
               (scalar.value >= 0x41 && scalar.value <= 0x5A) ||
               (scalar.value >= 0x61 && scalar.value <= 0x7A) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }

        if lastWasSpace, !result.isEmpty {
            result.removeLast()
        }

        return result
    }
}
