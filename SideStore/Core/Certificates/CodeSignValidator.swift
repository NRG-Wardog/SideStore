// V3_HOST_SIGNING_VALIDATOR_QUIET_V1
//
//  CodeSignValidator.swift
//  SideStore
//
//  Created by Magesh K on 6/28/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

public enum CodeSignValidationReason: Error {
    /// The certificate used to sign the current installation has expired.
    case expired
    
    /// The certificate was explicitly revoked on the Apple Developer portal.
    case revoked
    
    /// The certificate was automatically revoked because a free account is limited to 1 active certificate.
    case freeAccountLimitRevoked
    
    /// The active developer team has changed.
    case differentTeam
    
    /// The logged-in Apple ID account has changed.
    case differentAccount
    
    /// The private key for the active certificate is missing from the device's keychain.
    case privateKeyLost
    
    /// SideStore was installed by an external tool (e.g., Xcode or AltStore) using a different certificate.
    case externalSigner
    
    /// The current installation's provisioning profile is missing or invalid.
    case missingProfile
    
    /// Could not extract the leaf signing certificate from the app binary.
    case missingCertificate
}

public struct CodeSignValidator {
    
    public static func validate(
        runningProfile: ALTProvisioningProfile?,
        observedRunningCertificate: ALTX509Certificate? = nil,
        portalCertificates: [ALTX509Certificate]?,
        signerCertificate: ALTX509Certificate,
        signerTeam: ALTTeam
    ) -> Result<Void, CodeSignValidationReason> {
        
        guard let runningProfile = runningProfile else {
            /* Local signing details are intentionally not logged. */
            return .failure(.missingProfile)
        }
        
        let runningCert = observedRunningCertificate ?? CertificateManager.shared.getSigningCertificate(at: Bundle.Info.activeBundleURL)
        guard let runningCert = runningCert else {
            /* Local signing details are intentionally not logged. */
            return .failure(.missingCertificate)
        }
        
        // 1. Expired Certificate / Profile
        if runningProfile.expirationDate <= Date() {
            /* Local signing details are intentionally not logged. */
            return .failure(.expired)
        } else if runningCert.expiryDate <= Date() {
            /* Local signing details are intentionally not logged. */
            return .failure(.expired)
        }
        
        // 2. Different Account / Team
        let runningTeamID = runningProfile.teamIdentifier
        if runningTeamID != signerTeam.identifier {
            // Check if the Apple ID email matches.
            if let requesterEmail = runningCert.requesterEmail, !requesterEmail.isEmpty,
                let activeAppleID = signerTeam.account?.appleID,
                requesterEmail.lowercased() != activeAppleID.lowercased() 
            {
                /* Local signing details are intentionally not logged. */
                return .failure(.differentAccount)
            } else {
                /* Local signing details are intentionally not logged. */
                return .failure(.differentTeam)
            }
        }
        
        // 3. Revoked Certificate (Only checked if portal certificates were fetched)
        if let portalCertificates = portalCertificates {
            let isRunningCertActive = portalCertificates.contains { $0.serialNumber == runningCert.serialNumber }
            if !isRunningCertActive {
                if signerTeam.type == .free {
                    /* Local signing details are intentionally not logged. */
                    return .failure(.freeAccountLimitRevoked)
                } else {
                    /* Local signing details are intentionally not logged. */
                    return .failure(.revoked)
                }
            }
        }
        
        // 4. Mismatch / Private Key Lost / External Signer
        let hasCurrentSignerCert = runningProfile.certificates.contains { $0.serialNumber == signerCertificate.serialNumber }
        if !hasCurrentSignerCert {
            if let machineName = runningCert.machineName, (machineName.starts(with: "SideStore") || machineName.starts(with: "AltStore")) {
                /* Local signing details are intentionally not logged. */
                return .failure(.privateKeyLost)
            } else {
                /* Local signing details are intentionally not logged. */
                return .failure(.externalSigner)
            }
        }
        
        /* Local signing details are intentionally not logged. */
        return .success(())
    }
}
