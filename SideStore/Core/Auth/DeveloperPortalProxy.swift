//
//  DeveloperPortalProxy.swift
//  SideStore
//
//  Created by Magesh K on 2026-06-29.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import CoreData
import SideSign

public class DeveloperPortalProxy {
    public static let shared: DeveloperPortalProxy = DeveloperPortalProxyWithAuth()
    
    public static var currentDeviceType: ALTDeviceType {
        #if os(tvOS)
        return .tv
        #elseif os(visionOS)
        return .vision
        #elseif os(watchOS)
        return .watch
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
        #endif
    }
    
    fileprivate init() {}
    
    // V3_AUTH_IDENTITY_BOUND_DEVELOPER_PORTAL_V1
    private struct BoundSession {
        let session: ALTAppleAPISession
        let appleID: String
        let generation: UInt64
        let identityStamp: String
    }

    private func getBoundSession() async throws -> BoundSession {
        let auth = AuthManager.shared
        guard auth.v3IdentityIsStable else { throw OperationError.notAuthenticated }
        let generation = auth.v3IdentityGeneration
        let identityStamp = auth.v3IdentityStamp
        let credentialsBefore = auth.authenticationSnapshot
        let session = try await auth.getAuthenticatedSession()
        let credentials = auth.authenticationSnapshot
        guard V3AuthIdentityBindingPolicy.hasUsableSession(
            credentialRoutePresent: credentials?.isAuthenticated == true,
            dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken,
            sessionDSID: session.dsid, sessionXcodeToken: session.authToken,
            generationBefore: generation,
            generationAfter: auth.v3IdentityGeneration),
              V3AuthIdentityBindingPolicy.sameCredentialRoute(
                appleIDBefore: credentialsBefore?.appleIDEmailAddress,
                appleIDAfter: credentials?.appleIDEmailAddress,
                dsidBefore: credentialsBefore?.appleIDAdsid, dsidAfter: credentials?.appleIDAdsid,
                tokenBefore: credentialsBefore?.appleIDXcodeToken, tokenAfter: credentials?.appleIDXcodeToken),
              V3AuthIdentityBindingPolicy.mayDispatch(generationBefore: generation,
                generationAfter: auth.v3IdentityGeneration, cancelled: Task.isCancelled),
              auth.v3IdentityIsStable, identityStamp == auth.v3IdentityStamp,
              let appleID = credentials?.appleIDEmailAddress else {
            throw OperationError.notAuthenticated
        }
        return BoundSession(session: session, appleID: appleID, generation: generation,
            identityStamp: identityStamp)
    }

    private func verifyCurrent(_ context: BoundSession) throws {
        let auth = AuthManager.shared
        let credentials = auth.authenticationSnapshot
        guard V3AuthReadStampPolicy.mayReturn(capturedStamp: context.identityStamp,
              currentStamp: auth.v3IdentityStamp, stable: auth.v3IdentityIsStable),
              context.generation == auth.v3IdentityGeneration,
              V3AuthIdentityBindingPolicy.mayDispatch(generationBefore: context.generation,
                generationAfter: auth.v3IdentityGeneration, cancelled: Task.isCancelled),
              V3AuthIdentityBindingPolicy.hasUsableSession(
                credentialRoutePresent: credentials?.isAuthenticated == true,
                dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken,
                sessionDSID: context.session.dsid, sessionXcodeToken: context.session.authToken,
                generationBefore: context.generation,
                generationAfter: auth.v3IdentityGeneration),
              V3AuthIdentityBindingPolicy.mayUseTeam(
                sessionOwner: context.appleID, teamOwner: credentials?.appleIDEmailAddress) else {
            throw OperationError.notAuthenticated
        }
    }

    private func awaitBound<T>(_ context: BoundSession,
                               operation: () async throws -> T) async throws -> T {
        try verifyCurrent(context)
        let value = try await operation()
        try verifyCurrent(context)
        return value
    }

    private struct DatabaseTeamOwnershipSnapshot: Sendable {
        let teamOwners: [String]
        let activeTeamIdentifier: String?
        let activeAccountOwner: String?
    }

    private func databaseOwnershipSnapshot(for identifier: String) async throws -> DatabaseTeamOwnershipSnapshot {
        try await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            // Pin SQLite reads to one generation. In-memory Core Data stores
            // do not support query generations, but this closure still reads
            // every ownership fact on the same private context queue.
            if context.persistentStoreCoordinator?.persistentStores.contains(
                where: { $0.type == NSSQLiteStoreType }) == true {
                try context.setQueryGenerationFrom(.current)
            }
            let request = NSFetchRequest<Team>(entityName: "Team")
            request.predicate = NSPredicate(format: "%K == %@", #keyPath(Team.identifier), identifier)
            let matches = try context.fetch(request)
            let owners = Set(matches.compactMap { $0.account?.appleID }
                .compactMap(V3AuthIdentityBindingPolicy.normalizedOwner)).sorted()
            let activeTeamIdentifier = DatabaseManager.shared.activeTeam(in: context)?.identifier
            let activeAccountOwner = DatabaseManager.shared.activeAccount(in: context)?.appleID
            return DatabaseTeamOwnershipSnapshot(teamOwners: owners,
                activeTeamIdentifier: activeTeamIdentifier, activeAccountOwner: activeAccountOwner)
        }
    }

    private func owner(for team: ALTTeam, context: BoundSession) async throws -> String? {
        let directOwner = V3AuthIdentityBindingPolicy.normalizedOwner(team.account?.appleID)
        // SideSign's fetchTeams(for:session:) binds each returned ALTTeam to
        // the requested ALTAccount. Trust that explicit owner; a prior DB row
        // with the same team identifier may belong to a different account.
        if let directOwner { return directOwner }
        let databaseSnapshot = try await databaseOwnershipSnapshot(for: team.identifier)
        return V3AuthIdentityBindingPolicy.resolveColdTeamOwner(
            storedTeamOwners: databaseSnapshot.teamOwners,
            activeTeamIdentifier: databaseSnapshot.activeTeamIdentifier,
            requestedTeamIdentifier: team.identifier,
            activeAccountOwner: databaseSnapshot.activeAccountOwner,
            sessionOwner: context.appleID)
    }

    private func getBoundTeam(_ team: ALTTeam? = nil, context: BoundSession) async throws -> ALTTeam {
        let resolved: ALTTeam
        if let team { resolved = team }
        else { resolved = try await AuthManager.shared.getAuthenticatedTeam() }
        let owner = try await owner(for: resolved, context: context)
        try verifyCurrent(context)
        guard V3AuthIdentityBindingPolicy.mayDispatchTeamRequest(
            sessionOwner: context.appleID, teamOwner: owner,
            generationBefore: context.generation,
            generationAfter: AuthManager.shared.v3IdentityGeneration,
            cancelled: Task.isCancelled) else {
            throw OperationError.notAuthenticated
        }
        return resolved
    }

    
    public func fetchTeams(for account: ALTAccount) async throws -> [ALTTeam] {
        let context = try await self.getBoundSession()
        try self.verifyCurrent(context)
        guard V3AuthIdentityBindingPolicy.mayFetchTeams(sessionOwner: context.appleID,
            requestedOwner: account.appleID, generationBefore: context.generation,
            generationAfter: AuthManager.shared.v3IdentityGeneration,
            cancelled: Task.isCancelled) else {
            throw OperationError.notAuthenticated
        }
        let teams = try await self.awaitBound(context) {
            try await self.awaitBound(context) { try await ALTAppleAPI.shared.fetchTeams(for: account, session: context.session) }
        }
        try self.verifyCurrent(context)
        return teams
    }
    
    public func fetchCertificates(team: ALTTeam? = nil) async throws -> [ALTX509Certificate] {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.fetchCertificates(for: team, session: session) }
    }
    
    @discardableResult
    public func createCertificate(machineName: String, type: CertificateType = .development, team: ALTTeam? = nil) async throws -> ALTCertificate {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.addCertificate(machineName: machineName, type: type, to: team, session: session) }
    }
    
    @discardableResult
    public func revokeCertificate(_ certificate: ALTX509Certificate, team: ALTTeam? = nil) async throws -> Bool {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.revokeCertificate(certificate, for: team, session: session) }
    }
    
    public func fetchDevices(for team: ALTTeam? = nil, types: ALTDeviceType = .all) async throws -> [ALTDevice] {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.fetchDevices(for: team, types: types, session: session) }
    }
    
    @discardableResult
    public func registerDevice(name: String, identifier: String, type: ALTDeviceType = DeveloperPortalProxy.currentDeviceType, team: ALTTeam? = nil) async throws -> ALTDevice {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.registerDevice(name: name, identifier: identifier, type: type, team: team, session: session) }
    }

    @discardableResult
    public func updateDevice(_ device: ALTDevice, team: ALTTeam? = nil) async throws -> ALTDevice {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.updateDevice(device, team: team, session: session) }
    }

    @discardableResult
    public func disableDevice(_ device: ALTDevice, team: ALTTeam? = nil) async throws -> ALTDevice {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.disableDevice(device, team: team, session: session) }
    }

    @discardableResult
    public func deleteDevice(_ device: ALTDevice, team: ALTTeam? = nil) async throws -> Bool {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.deleteDevice(device, team: team, session: session) }
    }

    public func fetchAppIDs(team: ALTTeam? = nil) async throws -> [ALTAppID] {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "appIDLookup", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation)) { try await ALTAppleAPI.shared.fetchAppIDs(for: team, session: session) } }
    }

    public func fetchAppIDs(for team: ALTTeam) async throws -> [ALTAppID] {
        try await self.fetchAppIDs(team: team)
    }

    @discardableResult
    public func addAppID(name: String, bundleIdentifier: String, team: ALTTeam? = nil) async throws -> ALTAppID {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "appIDRegistration", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, bundleID: bundleIdentifier)) { try await ALTAppleAPI.shared.addAppID(withName: name, bundleIdentifier: bundleIdentifier, team: team, session: session) } }
    }

    @discardableResult
    public func updateAppID(_ appID: ALTAppID, team: ALTTeam? = nil) async throws -> ALTAppID {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "appIDCapabilitiesUpdate", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, bundleID: appID.bundleIdentifier, features: Dictionary(uniqueKeysWithValues: appID.features.map { ($0.key.rawValue, $0.value) }))) { try await ALTAppleAPI.shared.updateAppID(appID, team: team, session: session) } }
    }

    @discardableResult
    public func deleteAppID(_ appID: ALTAppID, team: ALTTeam? = nil) async throws -> Bool {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.deleteAppID(appID, for: team, session: session) }
    }

    @discardableResult
    public func deleteAppID(_ appID: ALTAppID, for team: ALTTeam) async throws -> Bool {
        try await self.deleteAppID(appID, team: team)
    }

    public func fetchAppGroups(team: ALTTeam? = nil) async throws -> [ALTAppGroup] {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "appGroupLookup", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation)) { try await ALTAppleAPI.shared.fetchAppGroups(for: team, session: session) } }
    }

    public func fetchAppGroups(for team: ALTTeam) async throws -> [ALTAppGroup] {
        try await self.fetchAppGroups(team: team)
    }

    @discardableResult
    public func addAppGroup(name: String, groupIdentifier: String, team: ALTTeam? = nil) async throws -> ALTAppGroup {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "appGroupRegistration", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, groupCount: 1, groupID: groupIdentifier)) { try await ALTAppleAPI.shared.addAppGroup(name: name, groupIdentifier: groupIdentifier, team: team, session: session) } }
    }

    @discardableResult
    public func updateAppGroup(_ group: ALTAppGroup, team: ALTTeam? = nil) async throws -> ALTAppGroup {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.updateAppGroup(group, team: team, session: session) }
    }

    @discardableResult
    public func assignAppID(_ appID: ALTAppID, to groups: [ALTAppGroup], team: ALTTeam? = nil) async throws -> ALTAppID {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "appGroupAssignment", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, bundleID: appID.bundleIdentifier, groupCount: groups.count)) { try await ALTAppleAPI.shared.assign(appID, to: groups, team: team, session: session) } }
    }

    @discardableResult
    public func assign(_ appID: ALTAppID, to groups: [ALTAppGroup], team: ALTTeam? = nil) async throws -> ALTAppID {
        try await self.assignAppID(appID, to: groups, team: team)
    }

    @discardableResult
    public func deleteAppGroup(_ group: ALTAppGroup, team: ALTTeam? = nil) async throws -> Bool {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.deleteAppGroup(group, team: team, session: session) }
    }

    public func listProvisioningProfiles(includeTeamProfiles: Bool = true, team: ALTTeam? = nil) async throws -> [ALTListedProvisioningProfile] {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.listProvisioningProfiles(includeTeamProfiles: includeTeamProfiles, for: team, session: session) }
    }

    public func downloadProvisioningProfile(for appID: ALTAppID, isTeamProfile: Bool = true, deviceType: ALTDeviceType = DeveloperPortalProxy.currentDeviceType, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "provisioningProfileRetrieval", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, bundleID: appID.bundleIdentifier, profileMode: isTeamProfile ? "team" : "manual")) { try await ALTAppleAPI.shared.downloadProvisioningProfile(for: appID, isTeamProfile: isTeamProfile, deviceType: deviceType, team: team, session: session) } }
    }

    public func downloadProvisioningProfile(for appID: ALTAppID, isTeamProfile: Bool = true, type: ALTProfileType, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "provisioningProfileRetrieval", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, bundleID: appID.bundleIdentifier, profileMode: isTeamProfile ? "team" : "manual")) { try await ALTAppleAPI.shared.downloadProvisioningProfile(for: appID, isTeamProfile: isTeamProfile, type: type, team: team, session: session) } }
    }

    public func downloadProvisioningProfile(profileID: String, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "provisioningProfileRetrieval", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, profileMode: "manual")) { try await ALTAppleAPI.shared.downloadProvisioningProfile(profileID: profileID, team: team, session: session) } }
    }

    public func createProvisioningProfile(name: String, appID: ALTAppID, certificateIDs: [String], deviceIDs: [String], team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        #if os(tvOS)
        let subPlatform: String? = "tvOS"
        #else
        let subPlatform: String? = nil
        #endif
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "provisioningProfileCreation", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, bundleID: appID.bundleIdentifier, profileMode: "manual")) { try await ALTAppleAPI.shared.createProvisioningProfile(name: name, appID: appID, certificateIDs: certificateIDs, deviceIDs: deviceIDs, subPlatform: subPlatform, team: team, session: session) } }
    }

    public func createProvisioningProfile(name: String, appID: ALTAppID, certificateIDs: [String], deviceIDs: [String] = [], type: ALTProfileType, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "provisioningProfileCreation", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, bundleID: appID.bundleIdentifier, profileMode: "manual")) { try await ALTAppleAPI.shared.createProvisioningProfile(name: name, appID: appID, certificateIDs: certificateIDs, deviceIDs: deviceIDs, type: type, team: team, session: session) } }
    }

    public func updateProvisioningProfile(profileID: String, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        #if os(tvOS)
        let subPlatform: String? = "tvOS"
        #else
        let subPlatform: String? = nil
        #endif
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "provisioningProfileUpdate", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, profileMode: "manual")) { try await ALTAppleAPI.shared.updateProvisioningProfile(profileID: profileID, name: name, appIDId: appIDId, certificateIDs: certificateIDs, deviceIDs: deviceIDs, subPlatform: subPlatform, team: team, session: session) } }
    }

    public func updateProvisioningProfile(profileID: String, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String] = [], type: ALTProfileType, team: ALTTeam? = nil) async throws -> ALTProvisioningProfile {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await lcPortalSigningRequest(sourceStep: "provisioningProfileUpdate", facts: lcPortalSigningContext(teamID: team.identifier, generation: context.generation, profileMode: "manual")) { try await ALTAppleAPI.shared.updateProvisioningProfile(profileID: profileID, name: name, appIDId: appIDId, certificateIDs: certificateIDs, deviceIDs: deviceIDs, type: type, team: team, session: session) } }
    }

    @discardableResult
    public func deleteProvisioningProfile(profileID: String, team: ALTTeam? = nil) async throws -> Bool {
        let context = try await self.getBoundSession()
        let session = context.session
        let team = try await self.getBoundTeam(team, context: context)
        return try await self.awaitBound(context) { try await ALTAppleAPI.shared.deleteProvisioningProfile(profileID: profileID, team: team, session: session) }
    }
}

class DeveloperPortalProxyWithAuth: DeveloperPortalProxy {
    fileprivate override init() {
        super.init()
    }

    func fetchAccount(session: ALTAppleAPISession) async throws -> ALTAccount {
        try await ALTAppleAPI.shared.fetchAccount(session: session)
    }

    func signIn(appleID: String, 
                password: String, 
                anisetteData: ALTAnisetteData, 
                xcodeVersion: String, 
                machinePassword: String? = nil,
                accountRepairHandler: DeveloperPortal.AccountRepairHandler = DeveloperPortal.defaultAccountRepairHandler,
                verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> (ALTAccount, ALTAppleAPISession) 
    {
        let authSession = try await ALTAppleAPI.shared.authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisetteData,
            xcodeVersion: xcodeVersion,
            machinePassword: machinePassword,
            accountRepairHandler: accountRepairHandler,
            verificationHandler: verificationHandler
        )
        return (authSession.account, authSession.session)
    }
    
    func authenticateWithToken(adsid: String, xcodeToken: String, anisetteData: ALTAnisetteData, xcodeVersion: String) async throws -> (ALTAccount, ALTAppleAPISession) {
        let session = ALTAppleAPISession(dsid: adsid, authToken: xcodeToken, anisetteData: anisetteData, xcodeVersion: xcodeVersion)
        let account = try await fetchAccount(session: session)
        return (account, session)
    }
}
