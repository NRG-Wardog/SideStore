//
//  StandaloneExecutionHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

protocol AnisetteServerHandler: AnyObject {
    func warnOutdatedAnisetteServer() async throws -> Bool
}

enum ProvisioningErrorDecision {
    case retry
    case cancel
    // Preserve the upstream choice without treating partial headless provisioning as success.
    case skip
}

enum RevokeDecision {
    case keepExisting
    case revokeSelected([ALTX509Certificate])
}

protocol SignInHandler: AnyObject {
    func credentials() async throws -> (String, String)
    func verificationCode(for request: TwoFactorRequest) async throws -> TwoFactorResponse
    func accountRepair(url: URL, message: String) async -> AccountRepairDecision
    func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async
    
    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam
    func resolveProvisioningError(_ error: Error) async -> ProvisioningErrorDecision
    func resolvePostAuth() async
    
    func resolveRevocation(certificates: [ALTX509Certificate], teamType: ALTTeamType) async throws -> RevokeDecision
    func resolveResign(mismatchReason: CodeSignValidationReason, context: StandaloneOperationContext) async throws -> Bool
    
    func complete() async
}

