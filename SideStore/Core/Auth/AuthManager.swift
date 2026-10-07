//
//  AuthManager.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign
import CoreData

public final class AuthManager: @unchecked Sendable {
    public static let shared = AuthManager()
    
    private var portalProxy: DeveloperPortalProxyWithAuth {
        DeveloperPortalProxy.shared as! DeveloperPortalProxyWithAuth
    }
    
    private init() {}

    // V3_AUTH_IDENTITY_GENERATION_V1: one AuthManager-owned process stamp and transition gate.
    private let v3IdentityStampState = V3AuthIdentityStampState()
    var v3IdentityGeneration: UInt64 {
        v3IdentityStampState.snapshot.generation
    }
    var v3IdentityStamp: String {
        v3IdentityStampState.snapshot.stamp
    }
    var v3IdentityIsStable: Bool {
        v3IdentityStampState.snapshot.stable
    }
    func v3BeginIdentityTransition() {
        v3IdentityStampState.beginTransition()
    }
    func v3CompleteIdentityTransition() {
        v3IdentityStampState.completeTransition()
    }
    func v3ReplaceSession(_ session: ALTAppleAPISession?) {
        v3BeginIdentityTransition()
        defer { v3CompleteIdentityTransition() }
        self.session = session
    }
    func v3InstallSessionIfCurrent(_ session: ALTAppleAPISession, capturedStamp: String) -> Bool {
        v3IdentityStampState.runIfCurrent(capturedStamp) { self.session = session }
    }
    func v3CachedSessionMatchesCurrentRoute(_ session: ALTAppleAPISession?) -> Bool {
        let identityAtStart = v3IdentityStampState.snapshot
        guard identityAtStart.stable, let session,
              let credentials = authenticationSnapshot else { return false }
        let identityAfterRead = v3IdentityStampState.snapshot
        return V3AuthReadStampPolicy.mayReturn(capturedStamp: identityAtStart.stamp,
                  currentStamp: identityAfterRead.stamp, stable: identityAfterRead.stable) &&
            V3AuthIdentityBindingPolicy.hasUsableSession(
                credentialRoutePresent: credentials.isAuthenticated,
                dsid: credentials.appleIDAdsid, xcodeToken: credentials.appleIDXcodeToken,
                sessionDSID: session.dsid, sessionXcodeToken: session.authToken,
                generationBefore: identityAtStart.generation,
                generationAfter: identityAfterRead.generation)
    }
    func v3AdvanceIdentityGeneration() {
        v3IdentityStampState.advanceGeneration()
    }
    
    public var team: ALTTeam?
    public var session: ALTAppleAPISession?

    // LC_AUTH_CREDENTIAL_SNAPSHOT_V1
    var authenticationSnapshot: LCEmbeddedAuthenticationSnapshot? {
        try? Keychain.shared.authenticationSnapshot()
    }

    public var isAuthenticated: Bool {
        authenticationSnapshot?.isAuthenticated ?? false
    }
    
    public var currentAppleID: String? {
        get { Keychain.shared.appleIDEmailAddress }
        set { self.v3BeginIdentityTransition(); defer { self.v3CompleteIdentityTransition() }; Keychain.shared.appleIDEmailAddress = newValue }
    }
    
    public var password: String? {
        get { Keychain.shared.appleIDPassword }
        set { self.v3BeginIdentityTransition(); defer { self.v3CompleteIdentityTransition() }; Keychain.shared.appleIDPassword = newValue }
    }
    
    public var adsid: String? {
        get { Keychain.shared.appleIDAdsid }
        set { self.v3BeginIdentityTransition(); defer { self.v3CompleteIdentityTransition() }; Keychain.shared.appleIDAdsid = newValue }
    }
    
    public var xcodeToken: String? {
        get { Keychain.shared.appleIDXcodeToken }
        set { self.v3BeginIdentityTransition(); defer { self.v3CompleteIdentityTransition() }; Keychain.shared.appleIDXcodeToken = newValue }
    }
    
    public var hasStoredPassword: Bool {
        return authenticationSnapshot?.hasPasswordCredentials ?? false
    }
    
    public var hasStoredXcodeToken: Bool {
        return authenticationSnapshot?.hasTokenCredentials ?? false
    }
    
    public func signOut(
        keepCertificate: Bool = false,
        keepAnisetteData: Bool = true,
        keepAnisetteHeaders: Bool = true,
        keepSideSignHeaders: Bool = true
    ) {
        self.v3BeginIdentityTransition()
        defer { self.v3CompleteIdentityTransition() }
        self.session = nil
        self.team = nil
        if !keepCertificate {
            debugLog("[AuthManager] Clearing signing certificate in cert manager and keychain.")
            CertificateManager.shared.clearActiveCertificate()
            debugLog("[AuthManager] Cleared signing certificate in cert manager and keychain.")

        } else {
            debugLog("[AuthManager] Preserved signing certificate in cert manager and keychain.")
        }
        debugLog("[AuthManager] Clearing account and team info in database.")
        DatabaseManager.shared.deactivateActiveAccountAndTeam()
        debugLog("[AuthManager] Cleared account and team info in database.")

        debugLog("[AuthManager] Clearing sign-in info from keychain.")
        Keychain.shared.clearSignInInfo(keepAnisetteData: keepAnisetteData)
        debugLog("[AuthManager] Cleared sign-in info from keychain.")

        if !keepAnisetteHeaders {
            debugLog("[AuthManager] Resetting Anisette header customizations to defaults.")
            AnisetteConfigManager.shared.resetToDefaults()
        }

        if !keepSideSignHeaders {
            debugLog("[AuthManager] Resetting SideSign header customizations to defaults.")
            SideSignConfigManager.shared.resetToDefaults()
        }

        AnisetteDataManager.shared.clearCache()
    }
    
    @discardableResult
    public func getAuthenticatedSession() async throws -> ALTAppleAPISession {
        let identityAtStart = v3IdentityStampState.snapshot
        guard identityAtStart.stable else { throw OperationError.notAuthenticated }
        return try await TaskChainCoalescer.shared.coalesce(
            key: V3AuthSessionCoalescerKey.value(for: identityAtStart.stamp)) {
            // LC_AUTHENTICATED_SESSION_SNAPSHOT_V1
            let credentialSnapshot: LCEmbeddedAuthenticationSnapshot?
            do { credentialSnapshot = try Keychain.shared.authenticationSnapshot() }
            catch { throw Keychain.shared.embeddedAuthenticationFailure(error) }
            guard let adsid = credentialSnapshot?.appleIDAdsid,
                  let xcodeToken = credentialSnapshot?.appleIDXcodeToken else {
                debugLog("[AuthManager] No stored tokens found.")
                throw OperationError.notAuthenticated
            }
            let anisetteData = try await AnisetteProvider.fetch()   // one time pass
            let xcodeVersion = await AnisetteConfigManager.shared.resolvedXcodeVersion()
            let credentialSnapshotAfter: LCEmbeddedAuthenticationSnapshot?
            do { credentialSnapshotAfter = try Keychain.shared.authenticationSnapshot() }
            catch { throw Keychain.shared.embeddedAuthenticationFailure(error) }
            guard self.v3IdentityIsStable,
                  self.v3IdentityStamp == identityAtStart.stamp,
                  credentialSnapshotAfter?.appleIDAdsid == adsid,
                  credentialSnapshotAfter?.appleIDXcodeToken == xcodeToken else {
                throw OperationError.notAuthenticated
            }
            
            let session = ALTAppleAPISession(
                dsid: adsid,
                authToken: xcodeToken,
                anisetteData: anisetteData,
                xcodeVersion: xcodeVersion
            )
            guard self.v3InstallSessionIfCurrent(session, capturedStamp: identityAtStart.stamp) else {
                throw OperationError.notAuthenticated
            }
            return session
        }
    }

    public func getAuthenticatedTeam() async throws -> ALTTeam {
        if let team = self.team {
            return team
        }
        
        let team = try await self.resolveActiveTeam()
        self.team = team
        return team
    }

    private func resolveActiveTeam() async throws -> ALTTeam {
        try await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            guard let dbTeam = DatabaseManager.shared.activeTeam(in: context) else {
                throw OperationError.notAuthenticated
            }
            return ALTTeam(identifier: dbTeam.identifier, name: dbTeam.name, type: dbTeam.type)
        }
    }
    
    // V3_HEADLESS_AUTH_ENTRYPOINT_V1: LiveContainer owns credentials and 2FA UI; the embedded service still executes SignInOperation through V3HeadlessAuthHandler.
    // Developer Portal Operations
    public func signIn(appleID: String, 
                       password: String, 
                       anisetteData: ALTAnisetteData, 
                       xcodeVersion: String, 
                       machinePassword: String? = nil,
                       accountRepairHandler: DeveloperPortal.AccountRepairHandler = DeveloperPortal.defaultAccountRepairHandler,
                       verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> (ALTAccount, ALTAppleAPISession) 
    {
        return try await self.portalProxy.signIn(
            appleID: appleID, 
            password: password, 
            anisetteData: anisetteData, 
            xcodeVersion: xcodeVersion, 
            machinePassword: machinePassword,
            accountRepairHandler: accountRepairHandler, 
            verificationHandler: verificationHandler
        )
    }
    
    public func authenticateWithToken(adsid: String,
                                      xcodeToken: String,
                                      anisetteData: ALTAnisetteData,
                                      xcodeVersion: String) async throws -> (ALTAccount, ALTAppleAPISession)
    {
        return try await self.portalProxy.authenticateWithToken(
            adsid: adsid,
            xcodeToken: xcodeToken,
            anisetteData: anisetteData,
            xcodeVersion: xcodeVersion
        )
    }
}

fileprivate extension DatabaseManager {
    //TODO: this is not clean, but for now this should be fine, ie we should later make this proper async instead of blocking
    func deactivateActiveAccountAndTeam() {
        guard self.isStarted else {
            debugLog("[AuthManager] DatabaseManager is not started. Skipping CoreData active account/team deactivation.")
            return
        }
        let bgContext = self.persistentContainer.newBackgroundContext()
        bgContext.performAndWait {
            if let account = self.activeAccount(in: bgContext) {
                account.isActiveAccount = false
            }
            if let team = self.activeTeam(in: bgContext) {
                team.isActiveTeam = false
            }
            do {
                try bgContext.save()
            } catch {
                debugLog("[AuthManager] Failed to save CoreData context when deactivating active account and team: \(error)")
            }
        }
        
        self.viewContext.performAndWait {
            self.viewContext.processPendingChanges()
            self.viewContext.refreshAllObjects()
        }
    }
}
