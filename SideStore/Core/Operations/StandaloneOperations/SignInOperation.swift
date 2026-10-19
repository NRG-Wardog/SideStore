// V3_CERTIFICATE_SERIAL_LOG_REDACTION_V1: certificate serials are password-equivalent and never logged.
//
//  SignInOperation.swift
//  SideStore
//
//  Created by Magesh K on 7/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import CoreData
import SideSign
import AnisetteKit

struct SignInResult {
    let team: ALTTeam
    let certificate: ALTCertificate?
    let session: ALTAppleAPISession
}

final class SignInOperation: BaseStandaloneOperation<StandaloneOperationContext, SignInResult>, @unchecked Sendable {
    
    // Own the trace across queued execution; unstructured operation tasks do not inherit callers.
    let loginDiagnosticTrace = LoginDiagnosticTrace.current ?? LoginDiagnosticTrace()

    private var appleIDEmailAddress: String?
    private var requiresPostAuthFlow = false
    private var portalCertificates: [ALTX509Certificate]?
    
    let signInHandler: SignInHandler
    let anisetteServerHandler: AnisetteServerHandler
    let skipDeviceRegistration: Bool
    let skipCertificateProvisioning: Bool
    // V3_PROVISIONING_RETRY_BYPASSES_CACHED_SIGNIN_V1
    let v3ForceProvisioningRetry: Bool
    // V3_PROVISIONING_REAUTHENTICATION_V1
    let v3RequireFullProvisioning: Bool
    let v3FinishPendingCertificateActivation: Bool
    // V3_EXPLICIT_SIGNIN_CREDENTIALS_V1: manual sign-in never replays saved credentials.
    let v3RequireInteractiveCredentials: Bool
    let v3ReauthenticateAppleID: String?
    let v3ReauthenticationIdentityStamp: String?
    private(set) var v3DidCompleteProvisioning = false

    init(
        context: StandaloneOperationContext,
        signInHandler: SignInHandler,
        anisetteServerHandler: AnisetteServerHandler,
        skipDeviceRegistration: Bool = false,
        skipCertificateProvisioning: Bool = false,
        v3ForceProvisioningRetry: Bool = false,
        v3RequireFullProvisioning: Bool = false,
        v3FinishPendingCertificateActivation: Bool = false,
        v3RequireInteractiveCredentials: Bool = false,
        v3ReauthenticateAppleID: String? = nil,
        v3ReauthenticationIdentityStamp: String? = nil
    ) throws {
        guard !v3FinishPendingCertificateActivation || v3RequireFullProvisioning else {
            throw V3PendingCertificateCreationError.pending
        }
        self.signInHandler = signInHandler
        self.anisetteServerHandler = anisetteServerHandler
        self.skipDeviceRegistration = skipDeviceRegistration
        self.skipCertificateProvisioning = skipCertificateProvisioning
        self.v3ForceProvisioningRetry = v3ForceProvisioningRetry
        self.v3RequireFullProvisioning = v3RequireFullProvisioning
        self.v3FinishPendingCertificateActivation = v3FinishPendingCertificateActivation
        self.v3RequireInteractiveCredentials = v3RequireInteractiveCredentials
        self.v3ReauthenticateAppleID = v3ReauthenticateAppleID
        self.v3ReauthenticationIdentityStamp = v3ReauthenticationIdentityStamp

        try super.init(context: context)
        self.debugLog("""
        [SignInOperation] Initialized with options:
          • skipDeviceRegistration: \(skipDeviceRegistration)
          • skipCertificateProvisioning: \(skipCertificateProvisioning)
        """)
    }

    private func getAnisetteData() async throws -> ALTAnisetteData {
        // V3_AUTHENTICATION_PHASE_EVIDENCE_V1
        try await v3LoginStage(.anisetteFetch) {
            try await v3AuthenticationPhase(.anisetteFetch) {
                try await AnisetteProvider.fetch(handler: self.anisetteServerHandler)
            }
        }
    }
    
    // Main Pipeline Execution
    override func execute(parentProgress: Progress?) async throws -> SignInResult {
        try await LoginDiagnosticTrace.$current.withValue(loginDiagnosticTrace) {
            try await v3LoginStage(.login) {
                try await self.executeLoginPipeline(parentProgress: parentProgress)
            }
        }
    }

    private func executeLoginPipeline(parentProgress: Progress?) async throws -> SignInResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[SignInOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[SignInOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await v3LoginStage(.preconditions) {
            try await super.executePreconditionCheck(parentProgress: parentProgress)
        }

        do {
            let authResult: SignInResult

            let route = LoginDiagnosticTrace.current?.begin(.credentialRoute)
            if self.v3ForceProvisioningRetry {
                route?.finish(.succeeded, reason: .retry)
                LoginDiagnosticTrace.current?.skip(.uiCredentials, reason: .notRequired)
                LoginDiagnosticTrace.current?.skip(.appleAuthentication, reason: .cached)
                let identityAtStart = AuthManager.shared.v3IdentityStamp
                let generationAtStart = AuthManager.shared.v3IdentityGeneration
                let credentials = v3LoginStageSync(.credentialRead) { AuthManager.shared.authenticationSnapshot }
                guard AuthManager.shared.v3IdentityIsStable,
                      var session = AuthManager.shared.session,
                      let team = AuthManager.shared.team,
                      let account = team.account,
                      let currentAppleID = credentials?.appleIDEmailAddress,
                      currentAppleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
                        account.appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      V3AuthIdentityBindingPolicy.hasUsableSession(
                        credentialRoutePresent: credentials?.isAuthenticated == true,
                        dsid: credentials?.appleIDAdsid, xcodeToken: credentials?.appleIDXcodeToken,
                        sessionDSID: session.dsid, sessionXcodeToken: session.authToken,
                        generationBefore: generationAtStart, generationAfter: AuthManager.shared.v3IdentityGeneration) else {
                    throw V3ProvisioningResumeUnavailableError()
                }
                session.anisetteData = try await self.getAnisetteData()
                let currentCredentials = AuthManager.shared.authenticationSnapshot
                guard V3AuthReadStampPolicy.mayReturn(capturedStamp: identityAtStart,
                        currentStamp: AuthManager.shared.v3IdentityStamp,
                        stable: AuthManager.shared.v3IdentityIsStable),
                      V3AuthIdentityBindingPolicy.sameCredentialRoute(
                        appleIDBefore: credentials?.appleIDEmailAddress,
                        appleIDAfter: currentCredentials?.appleIDEmailAddress,
                        dsidBefore: credentials?.appleIDAdsid, dsidAfter: currentCredentials?.appleIDAdsid,
                        tokenBefore: credentials?.appleIDXcodeToken, tokenAfter: currentCredentials?.appleIDXcodeToken),
                      V3AuthIdentityBindingPolicy.hasUsableSession(
                        credentialRoutePresent: currentCredentials?.isAuthenticated == true,
                        dsid: currentCredentials?.appleIDAdsid, xcodeToken: currentCredentials?.appleIDXcodeToken,
                        sessionDSID: session.dsid, sessionXcodeToken: session.authToken,
                        generationBefore: generationAtStart, generationAfter: AuthManager.shared.v3IdentityGeneration) else {
                    throw V3ProvisioningResumeUnavailableError()
                }
                guard AuthManager.shared.v3CachedSessionMatchesCurrentRoute(session) else {
                    throw V3ProvisioningResumeUnavailableError()
                }
                v3LoginStageSync(.sessionCommit) { AuthManager.shared.v3ReplaceSession(session) }
                authResult = try await self.provisioningLoop(account: account, session: session,
                    reportProgress: { [weak self] progress in self?.setProgress(progress) })
            } else if V3ProvisioningResumeExecutionPolicy.mayUseCachedSignIn(
                forceProvisioningRetry: self.v3ForceProvisioningRetry,
                requireFullProvisioning: self.v3RequireFullProvisioning),
               !self.v3RequireInteractiveCredentials,
               !self.v3FinishPendingCertificateActivation,
               var session = AuthManager.shared.session,
               AuthManager.shared.v3CachedSessionMatchesCurrentRoute(session),
               let team = AuthManager.shared.team,
               (self.skipCertificateProvisioning || CertificateManager.shared.activeCertificate != nil)
            {
                route?.finish(.succeeded, reason: .cached)
                LoginDiagnosticTrace.current?.skip(.uiCredentials, reason: .cached)
                LoginDiagnosticTrace.current?.skip(.appleAuthentication, reason: .cached)
                session.anisetteData = try await self.getAnisetteData()
                let certToUse = CertificateManager.shared.activeCertificate?.certificate
                
                self.debugLog("[SignInOperation] Using cached session, team, certificate")
                authResult = SignInResult(
                    team: team, 
                    certificate: certToUse, 
                    session: session
                )
            } else {
                route?.finish(.succeeded, reason: .fresh)
                authResult = try await self.startAuthentication { [weak self] progress in
                    self?.setProgress(progress)
                }
            }
            
            guard AuthManager.shared.v3CachedSessionMatchesCurrentRoute(authResult.session) else {
                throw V3ProvisioningResumeUnavailableError()
            }
            try await self.finalizeAuthentication(result: .success(authResult))
            self.setProgress(100)
            return authResult
        } catch {
            self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
            // V3_AUTH_FAILURE_PRESERVES_ACCOUNT_STATE_V1: explicit user Sign Out
            // owns account/keychain destruction; failed attempts are non-destructive.
            try? await self.finalizeAuthentication(result: .failure(error))
            throw error
        }
    }
    
    private func startAuthentication(reportProgress: @escaping @Sendable (Int64) -> Void) async throws -> SignInResult {
        // Explicit credentials own this attempt; saved routes remain available to background callers.
        if self.v3RequireInteractiveCredentials || self.v3ReauthenticateAppleID != nil {
            LoginDiagnosticTrace.current?.skip(.credentialRead, reason: .notRequired)
        }
        let silentResult = !self.v3RequireInteractiveCredentials && self.v3ReauthenticateAppleID == nil
            ? try await self.silentSignIn() : nil
        let (account, session) = if let silentResult {
            silentResult
        } else if V3ProvisioningResumeExecutionPolicy.mayPromptForCredentials(
            forceProvisioningRetry: self.v3ForceProvisioningRetry) {
            try await self.authenticationLoop()
        } else {
            throw V3ProvisioningResumeUnavailableError()
        }
        if let silentResult {
            await self.signInHandler.handleSignInResult(.success(silentResult))
        }
        v3LoginStageSync(.sessionCommit) { AuthManager.shared.v3ReplaceSession(session) }

        let authResult = try await self.provisioningLoop(
            account: account,
            session: session,
            reportProgress: reportProgress
        )
        
        return authResult
    }

    private func provisioningLoop(account: ALTAccount,
                                  session: ALTAppleAPISession,
                                  reportProgress: @escaping @Sendable (Int64) -> Void) async throws -> SignInResult
    {
        try await v3LoginStage(.provisioning) {
            try await self.performProvisioningLoop(account: account, session: session, reportProgress: reportProgress)
        }
    }

    private func performProvisioningLoop(account: ALTAccount, session: ALTAppleAPISession,
                                        reportProgress: @escaping @Sendable (Int64) -> Void) async throws -> SignInResult {
        let stepWeight: Int64 = self.skipDeviceRegistration ? 33 : 25
        reportProgress(stepWeight)

        var resolvedTeam: ALTTeam?
        var resolvedCertificate: ALTCertificate?

        var isCertificateResolved = false
        var isDeviceRegistered = false
        // V3_TYPED_ACCOUNT_DIAGNOSTICS_V1: owned stage, never provider text.
        var diagnosticStep: CombinedFailure.SourceStep = .fetchTeams

        while true {
            if self.isCancelled { throw OperationError.cancelled }

            do {
                // 1. Resolve Team & Save State
                if resolvedTeam == nil {
                    diagnosticStep = .fetchTeams
                    let team = try await self.fetchTeam(for: account, session: session)
                    AuthManager.shared.team = team

                    diagnosticStep = .saveAccount
                    try await self.saveTeamAndAccount(team)
                    reportProgress(stepWeight * 2)
                    resolvedTeam = team
                }

                guard let team = resolvedTeam else { continue }

                // 2. Resolve Certificate (Custom vs Developer Portal)
                if !isCertificateResolved {
                    let activeCert = CertificateManager.shared.activeCertificate?.certificate
                    let isCustomCert = activeCert?.data.map { data in
                        let details = parseCertificate(derData: data)
                        return !details.subject.contains(team.identifier) && !details.issuer.contains(team.identifier)
                    } ?? false
                    let pending = try Keychain.shared.pendingCertificateCreation()
                    if pending != nil && resolvedCertificate == nil && !self.v3FinishPendingCertificateActivation {
                        throw V3PendingCertificateCreationError.pending
                    }
                    if self.v3FinishPendingCertificateActivation && pending == nil && resolvedCertificate == nil {
                        throw V3PendingCertificateCreationError.pending
                    }
                    if isCustomCert && !self.v3FinishPendingCertificateActivation {
                        self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
                        resolvedCertificate = activeCert
                    } else if self.skipCertificateProvisioning && !self.v3FinishPendingCertificateActivation {
                        resolvedCertificate = activeCert
                    } else {
                        // Retain the obtained certificate across local save retries.
                        if resolvedCertificate == nil {
                            diagnosticStep = .fetchCertificate
                            resolvedCertificate = try await self.fetchCertificate(for: team, session: session)
                        }
                        if let certificate = resolvedCertificate {
                            diagnosticStep = .activateCertificate
                            try CertificateManager.shared.setActiveCertificate(certificate)
                            try CertificateManager.shared.v3CompletePendingCertificateIfStored(certificate)
                        }
                    }
                    isCertificateResolved = true
                }

                guard isCertificateResolved else { continue }

                // 3. Register Current Device
                if !isDeviceRegistered {
                    if !self.skipDeviceRegistration {
                        self.verboseLog("[SignInOperation] Registering current device...")
                        diagnosticStep = .registerDevice
                        let device = try await self.registerCurrentDevice(for: team, session: session)
                        self.debugLog("[SignInOperation] Current device registration completed.")
                        reportProgress(stepWeight * 3)
                    }
                    isDeviceRegistered = true
                }

                self.v3DidCompleteProvisioning = !self.skipDeviceRegistration &&
                    !self.skipCertificateProvisioning && resolvedCertificate != nil
                return SignInResult(
                    team: team,
                    certificate: resolvedCertificate,
                    session: session
                )
                
            } catch {
                if self.isCancelled { throw OperationError.cancelled }

                self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
                let diagnosticError = v3AccountOperationFailure(error, step: diagnosticStep)
                let decision = await self.signInHandler.resolveProvisioningError(diagnosticError)
                switch decision {
                    case .retry:
                        self.debugLog("[SignInOperation] User chose retry in provisioningLoop")
                        continue
                    case .cancel:
                        self.debugLog("[SignInOperation] User cancelled in provisioningLoop")
                        if diagnosticError.requiresReconciliation || diagnosticError.portalSessionRejected { throw diagnosticError }
                        throw OperationError.cancelled
                }
            }
        }
    }
    
    private func silentSignIn() async throws -> (ALTAccount, ALTAppleAPISession)? {
        // LC_SIGNIN_CREDENTIAL_SNAPSHOT_V1
        // LC_VERIFIED_LEGACY_AUTH_V1: routes are not yet bound identities.
        let capturedStamp = AuthManager.shared.v3IdentityStamp
        guard AuthManager.shared.v3IdentityIsStable else { throw OperationError.notAuthenticated }
        let candidate: LCEmbeddedAuthenticationCandidate?
        do { candidate = try v3LoginStageSync(.credentialRead) { try Keychain.shared.authenticationCandidate() } }
        catch { throw v3AccountOperationFailure(error, step: .credentialCommit) }
        let credentials = candidate?.credentials
        // Try silent auth using Keychain Token
        if let adsid = credentials?.appleIDAdsid,
           let xcodeToken = credentials?.appleIDXcodeToken {
            self.verboseLog("[SignInOperation] Authenticating Apple ID with tokens...")

            do {
                let anisetteData = try await self.getAnisetteData()
                let xcodeVersion = await AnisetteConfigManager.shared.resolvedXcodeVersion()

                let (account, session) = try await v3LoginStage(.accountLookup) {
                    try await v3AuthenticationPhase(.accountLookup) {
                        try await AuthManager.shared.authenticateWithToken(
                            adsid: adsid,
                            xcodeToken: xcodeToken,
                            anisetteData: anisetteData,
                            xcodeVersion: xcodeVersion
                        )
                    }
                }
                guard !self.isCancelled, !Task.isCancelled else { throw OperationError.cancelled }
                guard let candidate, AuthManager.shared.v3IdentityIsStable,
                      capturedStamp == AuthManager.shared.v3IdentityStamp,
                      account.identifier == session.dsid,
                      candidate.matchesVerifiedIdentity(appleID: account.appleID, dsid: session.dsid) else {
                    throw v3AccountOperationFailure(NSError(domain: "LiveContainerRefresh.Configuration", code: 1008), step: .credentialCommit)
                }
                AuthManager.shared.v3BeginIdentityTransition()
                defer { AuthManager.shared.v3CompleteIdentityTransition() }
                do {
                    try v3LoginStageSync(.credentialCommit) {
                        try Keychain.shared.writeVerifiedAuthentication(candidate, appleID: account.appleID,
                            dsid: session.dsid, authToken: session.authToken)
                    }
                } catch { throw v3AccountOperationFailure(error, step: .credentialCommit) }
                v3LoginStageSync(.sessionCommit) { AuthManager.shared.session = session }
                return (account, session)
            } catch {
                if error is V3AccountOperationError { throw error }
                if let phase = error as? V3AuthenticationPhaseError, phase.underlying is LCAnisettePairError { throw error }
                if self.isCancelled || Task.isCancelled || error is CancellationError { throw OperationError.cancelled }
                self.debugLog("[V3_AUTH] saved_token_verification_failed")
            }
        }
        
        // Try silent auth using Keychain Password
        if let appleID = credentials?.appleIDEmailAddress,
           let password = credentials?.appleIDPassword {
            self.debugLog("[SignInOperation] Authenticating Apple ID with saved password...")
            do {
                return try await self.signIn(appleID: appleID, password: password,
                    recoveryCandidate: candidate, capturedStamp: capturedStamp)
            } catch {
                if error is V3AccountOperationError { throw error }
                if let phase = error as? V3AuthenticationPhaseError, phase.underlying is LCAnisettePairError { throw error }
                self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
            }
        }

        return nil
    }

    private func authenticationLoop() async throws -> (account: ALTAccount, session: ALTAppleAPISession) {
        self.verboseLog("[SignInOperation] authenticationLoop: Requesting credentials...")
        let handler = self.signInHandler
        
        var retryCredentials: (String, String)?
        while true {
            let credentials: (String, String)
            if let retry = retryCredentials {
                LoginDiagnosticTrace.current?.skip(.uiCredentials, reason: .retry)
                credentials = retry
                retryCredentials = nil
            } else {
                credentials = try await v3LoginStage(.uiCredentials) { try await handler.credentials() }
            }
            let (appleID, password) = credentials
            if self.isCancelled { throw OperationError.cancelled }
            
            do {
                let (account, session) = try await self.signIn(appleID: appleID, password: password)
                self.debugLog("[SignInOperation] authenticationLoop: signIn succeeded.")
                
                await handler.handleSignInResult(.success((account, session)))
                
                self.requiresPostAuthFlow = true
                return (account, session)
            } catch {
                if error is V3ProvisioningReauthenticationIdentityError { throw error }
                if self.isCancelled || error is CancellationError || v3ClassifyAuthError(error) == nil {
                    throw OperationError.cancelled
                }
                self.debugLog("[V3_AUTH] attempt_failed")
                await handler.handleSignInResult(.failure(error))
                // A local commit failure must reconcile, never replay Apple login.
                if let local = error as? V3AccountOperationError, local.credentialCommit { throw local }
                if v3ClassifyAuthError(error)?.rawValue == "anisetteIdentityStateInvalid" { throw error }
                if V3TwoFactorRetryPolicy.shouldReuseCredentialsForCodeRetry(
                    authFailureKind: v3ClassifyAuthError(error)?.rawValue) {
                    retryCredentials = (appleID, password)
                }
            }
        }
    }
    
    private func v3ValidateReauthenticationIdentity(submittedAppleID: String, returnedAppleID: String? = nil, returnedDSID: String? = nil) throws {
        guard let expectedOwner = self.v3ReauthenticateAppleID else { return }
        let credentials = AuthManager.shared.authenticationSnapshot
        guard let stamp = self.v3ReauthenticationIdentityStamp,
              V3ProvisioningReauthenticationIdentityPolicy.mayAuthenticate(
                expectedOwner: expectedOwner, submittedOwner: submittedAppleID,
                currentOwner: credentials?.appleIDEmailAddress, capturedStamp: stamp,
                currentStamp: AuthManager.shared.v3IdentityStamp,
                identityStable: AuthManager.shared.v3IdentityIsStable),
              returnedAppleID == nil || V3AuthIdentityBindingPolicy.mayUseTeam(
                sessionOwner: expectedOwner, teamOwner: returnedAppleID),
              returnedDSID == nil || returnedDSID == credentials?.appleIDAdsid else {
            throw V3ProvisioningReauthenticationIdentityError()
        }
    }

    private func signIn(appleID: String, password: String,
                        recoveryCandidate: LCEmbeddedAuthenticationCandidate? = nil,
                        capturedStamp: String? = nil) async throws -> (ALTAccount, ALTAppleAPISession) {
        try self.v3ValidateReauthenticationIdentity(submittedAppleID: appleID)
        self.appleIDEmailAddress = appleID
        
        let anisetteData = try await self.getAnisetteData()
        let handler = self.signInHandler
        
        let xcodeVersion = await AnisetteConfigManager.shared.resolvedXcodeVersion()

        try self.v3ValidateReauthenticationIdentity(submittedAppleID: appleID)
        let (account, session) = try await v3LoginStage(.appleAuthentication) {
            try await v3AuthenticationPhase(.appleAuthentication) {
                try await AuthManager.shared.signIn(
                    appleID: appleID,
                    password: password,
                    anisetteData: anisetteData,
                    xcodeVersion: xcodeVersion,
                    accountRepairHandler: { url, message in
                        await handler.accountRepair(url: url, message: message)
                    },
                    verificationHandler: { request in
                        try await handler.verificationCode(for: request)
                    }
                )
            }
        }
        
        if self.isCancelled || Task.isCancelled { throw OperationError.cancelled }
        try self.v3ValidateReauthenticationIdentity(submittedAppleID: appleID, returnedAppleID: account.appleID, returnedDSID: session.dsid)
        // V3_AUTH_CREDENTIAL_TRANSACTION_V1: commit the complete credential route
        // and readiness marker together after exact read-back verification.
        if let candidate = recoveryCandidate {
            guard !self.isCancelled, !Task.isCancelled else { throw OperationError.cancelled }
            guard AuthManager.shared.v3IdentityIsStable, capturedStamp == AuthManager.shared.v3IdentityStamp,
                  account.identifier == session.dsid,
                  candidate.matchesVerifiedIdentity(appleID: account.appleID, dsid: session.dsid) else {
                throw v3AccountOperationFailure(NSError(domain: "LiveContainerRefresh.Configuration", code: 1008), step: .credentialCommit)
            }
        }
        AuthManager.shared.v3BeginIdentityTransition()
        defer { AuthManager.shared.v3CompleteIdentityTransition() }
        do {
            try v3LoginStageSync(.credentialCommit) {
                if let candidate = recoveryCandidate {
                    do {
                        try Keychain.shared.writeVerifiedAuthentication(candidate, appleID: account.appleID,
                            dsid: session.dsid, authToken: session.authToken)
                    } catch { throw v3AccountOperationFailure(error, step: .credentialCommit) }
                } else {
                    try Keychain.shared.writeAuthenticationCredentials(appleID: appleID, password: password, dsid: session.dsid, authToken: session.authToken)
                }
            }
        } catch {
            throw v3AccountOperationFailure(error, step: .credentialCommit)
        }
        v3LoginStageSync(.sessionCommit) { AuthManager.shared.session = session }
        
        return (account, session)
    }

    private func finalizeAuthentication(result: Result<SignInResult, Error>) async throws {
        try await v3LoginStage(.accountFinalize) {
            try await self.performFinalizeAuthentication(result: result)
        }
    }

    private func performFinalizeAuthentication(result: Result<SignInResult, Error>) async throws {
        self.verboseLog("[SignInOperation] finalizeAuthentication: Starting cleanup...")
        
        switch result {
            case .failure(let error):
                self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
                await v3LoginStage(.cleanup) { await self.signInHandler.complete() }
                self.verboseLog("[SignInOperation] finalizeAuthentication: invoked auth complete for .failure case...")
                
            case .success(let result):
                let team = result.team
                let certificate = result.certificate
                let session = result.session

                self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
                do {
                    try await self.saveTeamAndAccount(team, makeActive: true)
                } catch {
                    // V3_ACCOUNT_ACTIVATION_PERSISTENCE_V1: never publish activation after a failed save.
                    throw v3AccountOperationFailure(error, step: .activateAccount)
                }
                self.verboseLog("[SignInOperation] finalizeAuthentication: Database updates completed.")
                
                if let signingCertificate = certificate, !self.skipCertificateProvisioning
                {
                    let signer = ALTSigner(team: team, certificate: signingCertificate)
                    let didResign = try await self.validateCodeSign(signer: signer, session: session)
                    self.verboseLog("[SignInOperation] finalizeAuthentication: didResign = \(didResign)")
                    
                    if !didResign && self.requiresPostAuthFlow {
                        await self.signInHandler.resolvePostAuth()
                        self.verboseLog("[SignInOperation] finalizeAuthentication: post auth flow completed...")
                    }
                }
                
                await v3LoginStage(.cleanup) { await self.signInHandler.complete() }
                self.verboseLog("[SignInOperation] finalizeAuthentication: invoked auth complete for .success case...")
        }
    }
}

// Persistence and Codesign Validity Check Helpers
private extension SignInOperation {

    private func saveTeamAndAccount(_ altTeam: ALTTeam, makeActive: Bool = false) async throws {
        try await v3LoginStage(.accountSave) {
            try await self.performSaveTeamAndAccount(altTeam, makeActive: makeActive)
        }
    }

    private func performSaveTeamAndAccount(_ altTeam: ALTTeam, makeActive: Bool) async throws {
        let context = self.context.dbBackgroundContext
        let intended = ["account:" + (altTeam.account?.identifier ?? altTeam.identifier),
                        "team:" + altTeam.identifier].sorted()
        do {
            if makeActive {
                let previous = try await v3AccountDatabaseSnapshot()
                try V3AccountDatabaseRecovery.begin(previous: previous, intended: intended)
            }
            try await context.perform {
            let account: Account
            let team: Team
            
            let accountIdentifier = altTeam.account?.identifier ?? altTeam.identifier
            if let tempAccount = Account.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Account.identifier), accountIdentifier), in: context) {
                account = tempAccount
            } else if let altAccount = altTeam.account {
                account = Account(altAccount, context: context)
            } else {
                let altAccount = ALTAccount(appleID: self.appleIDEmailAddress ?? "", identifier: accountIdentifier)
                account = Account(altAccount, context: context)
            }
            
            if let tempTeam = Team.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Team.identifier), altTeam.identifier), in: context) {
                team = tempTeam
            } else {
                team = Team(altTeam, account: account, context: context)
            }
            
            if let altAccount = altTeam.account {
                account.update(account: altAccount)
            }

            if let providedEmailAddress = self.appleIDEmailAddress {
                account.appleID = providedEmailAddress
            }
            
            team.update(team: altTeam)
            
            if makeActive {
                // Account
                account.isActiveAccount = true
                let otherAccountsFetchRequest = Account.fetchRequest() as NSFetchRequest<Account>
                otherAccountsFetchRequest.predicate = NSPredicate(format: "%K != %@", #keyPath(Account.identifier), account.identifier)
                let otherAccounts = try context.fetch(otherAccountsFetchRequest)
                for otherAccount in otherAccounts {
                    otherAccount.isActiveAccount = false
                }

                // Team
                team.isActiveTeam = true
                let otherTeamsFetchRequest = Team.fetchRequest() as NSFetchRequest<Team>
                otherTeamsFetchRequest.predicate = NSPredicate(format: "%K != %@", #keyPath(Team.identifier), team.identifier)
                let otherTeams = try context.fetch(otherTeamsFetchRequest)
                for otherTeam in otherTeams {
                    otherTeam.isActiveTeam = false
                }


            }

            try context.save()
            if makeActive {
                let isSparseRestorePatched   = ProcessInfo().sparseRestorePatched
                let isAppLimitDisabled       = UserDefaults.standard.isAppLimitDisabled

                UserDefaults.standard.activeAppsLimit = nil
                if team.type == .free {
                    if !isAppLimitDisabled && isSparseRestorePatched ||
                        isAppLimitDisabled && !isSparseRestorePatched 
                    {
                        UserDefaults.standard.activeAppsLimit = InstalledApp.freeAccountActiveAppsLimit
                    }
                }
            }
            }
            if makeActive {
                let observed = try await v3AccountDatabaseSnapshot()
                guard observed == intended else {
                    throw NSError(domain: "LiveContainerRefresh.Configuration", code: 1011)
                }
                try V3AccountDatabaseRecovery.reconcile(observed: observed)
            }
        } catch {
            await context.perform { context.rollback() }
            if makeActive {
                do { try await v3ReconcileAccountDatabaseStorage() }
                catch { throw V3AccountDatabaseOutcomeUnknownError() }
            }
            throw error
        }
    }
    
    private func validateCodeSign(signer: ALTSigner, session: ALTAppleAPISession) async throws -> Bool {
        self.verboseLog("[SignInOperation] validateCodeSign: entering method")
        guard let appBundle = ALTApplication(fileURL: Bundle.Info.activeBundleURL), 
              let provisioningProfile = appBundle.provisioningProfile else 
        {
            self.verboseLog("[SignInOperation] validateCodeSign: Application bundle or provisioning profile nil, returning false")
            return false
        }
        
        let portalCertificates: [ALTX509Certificate]
        if let cached = self.portalCertificates {
            portalCertificates = cached
        } else {
            let fetched = try await DeveloperPortalProxy.shared.fetchCertificates(team: signer.team)
            self.portalCertificates = fetched
            portalCertificates = fetched
        }
        
        let result = CodeSignValidator.validate(
            runningProfile: provisioningProfile,
            portalCertificates: portalCertificates,
            signerCertificate: signer.certificate.x509,
            signerTeam: signer.team
        )
        
        switch result {
            case .success:
                self.verboseLog("[SignInOperation] validateCodeSign: Validation succeeded, no resign required.")
                return false
                
            case .failure(let reason):
                self.debugLog("[SignInOperation] Signing certificate mismatch detected: \(reason)")
                
                if signer.team.type != .free && (reason == .privateKeyLost || reason == .externalSigner) {
                    self.debugLog("[SignInOperation] Running certificate is still active on the Paid account portal. Skipping resign screen.")
                    return false
                }
                
                let handler = self.signInHandler
                do {
                    return try await handler.resolveResign(mismatchReason: reason, context: self.context)
                } catch {
                    self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
                    return false
                }
        }
    }
}

// Team, Certificate Resolution & Device Registration Helpers
private extension SignInOperation {

    private func fetchTeam(for account: ALTAccount, session: ALTAppleAPISession) async throws -> ALTTeam {
        self.verboseLog("[SignInOperation] fetchTeam: Requesting teams from Apple...")
        let teams = try await DeveloperPortalProxy.shared.fetchTeams(for: account)
        
        guard !teams.isEmpty else {
            throw DeveloperPortalError.noTeams
        }
        
        let selectedTeam: ALTTeam
        if teams.count == 1 {
            selectedTeam = teams[0]
        } else {
            self.debugLog("[SignInOperation] Multiple teams found (\(teams.count)). Prompting user for team selection...")
            selectedTeam = try await self.signInHandler.resolveTeam(teams)
        }
        
        self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
        return selectedTeam
    }

    private func fetchCertificate(for team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
        if let pending = try Keychain.shared.pendingCertificateCreation() {
            guard self.v3FinishPendingCertificateActivation, pending.purpose == .provisioning,
                  let certificate = try await DeveloperPortalProxy.shared.reconcilePendingCertificateCreation(team: team) else {
                throw V3PendingCertificateCreationError.pending
            }
            return certificate
        }
        guard !self.v3FinishPendingCertificateActivation else {
            throw V3PendingCertificateCreationError.pending
        }
        let portalCertificates = try await DeveloperPortalProxy.shared.fetchCertificates(team: team)
        self.portalCertificates = portalCertificates
        
        let mainBundleCertSerial = Bundle.main.object(forInfoDictionaryKey: Bundle.Info.certificateID) as? String
        
        if let activeCert = CertificateManager.shared.activeCertificate,
           let certificate = portalCertificates.first(where: { $0.serialNumber == activeCert.serialNumber }) 
        {
            var keyStoreCert = activeCert.certificate
            keyStoreCert.machineIdentifier = certificate.machineIdentifier

            if let mainBundleCertSerial = mainBundleCertSerial, 
                mainBundleCertSerial.lowercased() != activeCert.serialNumber.lowercased() 
            {
                self.debugLog("[SignInOperation] Certificate identity details omitted.")
            }
            return keyStoreCert
        }
        
        if let mainBundleCertSerial = mainBundleCertSerial,
           let certificate = portalCertificates.first(where: { $0.serialNumber.lowercased() == mainBundleCertSerial.lowercased() }),
           var cert = CertificateManager.shared.getSignableCertificate(for: mainBundleCertSerial, fallbackPassword: certificate.machineIdentifier) 
        {
            cert.machineIdentifier = certificate.machineIdentifier
            self.debugLog("[SignInOperation] Certificate identity details omitted.")
            return cert
        }
        
        if portalCertificates.isEmpty {
            return try await self.requestCertificate(for: team, session: session)
        } else {
            return try await self.replaceCertificate(portalCertificates: portalCertificates, for: team, session: session)
        }
    }

    private func requestCertificate(for team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
        let deviceName = await UIDevice.current.name
        let accountName = team.account?.firstName ?? team.name
        let machineName: String = "SideStore - \(accountName)'s \(deviceName)"
        self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")

        do {
            let newPortalCertificate = try await DeveloperPortalProxy.shared.createCertificate(machineName: machineName, team: team, purpose: .provisioning)
            self.debugLog("[SignInOperation] Certificate identity details omitted.")
            
            self.portalCertificates = nil
            return newPortalCertificate
        } catch {
            self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
            throw error
        }
    }

    private func replaceCertificate(portalCertificates: [ALTX509Certificate], for team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
        let iosCertificates = portalCertificates.filter { cert in
            let nameLower = cert.name.lowercased()
            return nameLower.contains("ios development") || nameLower.contains("iphone developer")
        }

        self.debugLog("[SignInOperation] replaceCertificate: Starting. Total certs on portal: \(portalCertificates.count), iOS Development certs: \(iosCertificates.count)")
        
        if iosCertificates.isEmpty {
            self.verboseLog("[SignInOperation] replaceCertificate: No iOS Development certificates found on portal. Requesting new...")
            return try await self.requestCertificate(for: team, session: session)
        }
        
        self.debugLog("[SignInOperation] replaceCertificate: Presenting revoke alert for \(iosCertificates.count) iOS Development cert(s)...")
        let action = try await self.signInHandler.resolveRevocation(certificates: iosCertificates, teamType: team.type)
        self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
        switch action {
            case .keepExisting:
                self.verboseLog("[SignInOperation] replaceCertificate: Keeping existing, calling requestCertificate...")
                return try await self.requestCertificate(for: team, session: session)
                
            case .revokeSelected(let certsToRevoke):
                self.debugLog("[SignInOperation] replaceCertificate: Revoking \(certsToRevoke.count) selected certificate(s)...")
                var firstError: Error? = nil

                for certificate in certsToRevoke {
                    do {
                        self.verboseLog("[SignInOperation] Certificate identity details omitted.")
                        _ = try await DeveloperPortalProxy.shared.revokeCertificate(certificate, team: team)
                        self.verboseLog("[SignInOperation] replaceCertificate: Revoke succeeded.")
                    } catch {
                        self.debugLog("[SignInOperation] Stage result recorded; private payload omitted.")
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }

                if let error = firstError {
                    self.debugLog("[SignInOperation] replaceCertificate: Error occurred during revocation, throwing...")
                    throw error
                } else {
                    self.debugLog("[SignInOperation] replaceCertificate: Selected certificates successfully revoked. Requesting new certificate...")
                    return try await self.requestCertificate(for: team, session: session)
                }
        }
    }
    
    @discardableResult
    private func registerCurrentDevice(for team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTDevice {
        self.debugLog("[SignInOperation] registerCurrentDevice starting...")
        var deviceQueryError: Error?
        var deviceUDID: String?
        do {
            await CellularRefreshManager.shared.turnOffDataIfNeeded()
            deviceUDID = try await fetchUDID()
            await CellularRefreshManager.shared.turnOnDataIfNeeded(addOnDelay: 2.0)
        } catch {
            await CellularRefreshManager.shared.turnOnDataIfNeeded(addOnDelay: 2.0)
            deviceQueryError = error
            self.debugLog("[SignInOperation] Primary device query failed.")
        }
        
        if deviceUDID == nil || deviceUDID?.isEmpty == true || deviceUDID == "XXXXX-XXXX-XXXXX-XXXX" {
            do { deviceUDID = try await fetchUDID(useStatic: true) }
            catch { deviceQueryError = deviceQueryError ?? error }
        }
        
        guard let udid = deviceUDID, !udid.isEmpty, udid != "XXXXX-XXXX-XXXXX-XXXX" else {
            self.debugLog("[SignInOperation] Failed to fetch device UDID.")
            if let deviceQueryError { throw deviceQueryError }
            throw OperationError.unknownUDID
        }
        self.debugLog("[SignInOperation] Device registration step.")
        
        let devices = try await DeveloperPortalProxy.shared.fetchDevices(for: team, types: .all)
        if let device = devices.first(where: { $0.identifier == udid }) {
            self.debugLog("[SignInOperation] Device registration step.")
            return device
        } else {
            let deviceName = await MainActor.run { UIDevice.current.name }
            self.debugLog("[SignInOperation] Device registration step.")
            let device = try await DeveloperPortalProxy.shared.registerDevice(name: deviceName, identifier: udid, type: DeveloperPortalProxy.currentDeviceType, team: team)
            self.debugLog("[SignInOperation] Device registration step.")
            return device
        }
    }
}

// LOGIN_STAGE_OBSERVER_V1: typed finite metadata only, preserve original errors and cancellation.
func v3LoginStage<T>(_ stage: LoginDiagnosticStage, perform: () async throws -> T) async rethrows -> T {
    let span = LoginDiagnosticTrace.current?.begin(stage)
    do {
        let result = try await perform()
        span?.finish(.succeeded)
        return result
    } catch {
        span?.finish(.failed, reason: v3IsAuthCancellation(error) ? .cancelled : .none, error: error)
        throw error
    }
}

func v3LoginStageSync<T>(_ stage: LoginDiagnosticStage, perform: () throws -> T) rethrows -> T {
    let span = LoginDiagnosticTrace.current?.begin(stage)
    do {
        let result = try perform()
        span?.finish(.succeeded)
        return result
    } catch {
        span?.finish(.failed, reason: v3IsAuthCancellation(error) ? .cancelled : .none, error: error)
        throw error
    }
}
