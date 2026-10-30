// V3_CERTIFICATE_SERIAL_LOG_REDACTION_V1: certificate serials are password-equivalent and never logged.
//
//  UpdateAppCertificateOperation.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import CoreData
import SideSign

final class UpdateAppCertificateOperation: BasePipelineOperation<InstallAppOperationContext, Void>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[UpdateAppCertificateOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[UpdateAppCertificateOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        if context.legacyReplacementBinding != nil {
            // Do not let a global assigned profile or fallback certificate replace
            // the per-operation identity explicitly confirmed by the owner.
            try await context.validateLegacyReplacementAdmission()
            self.setProgress(100)
            return
        }

        let targetBundleID = self.context.installedApp?.bundleIdentifier ?? self.context.targetBundleIdentifier
        let profileToUse = self.context.overrideProvisioningProfile ?? ProfileManager.shared.getAssignedProfile(for: targetBundleID)

        if let assignedProfile = profileToUse {
            debugLog("[UpdateAppCertificateOperation] Certificate identity details omitted.")
            self.context.overrideProvisioningProfile = assignedProfile

            if let matchingCert = ProfileManager.shared.getMatchingCertificate(for: assignedProfile) {
                debugLog("[UpdateAppCertificateOperation] Certificate identity details omitted.")
                self.context.overrideSigningCertificate = matchingCert
            } else if let serialNumber = self.context.installedApp?.certificateSerialNumber,
                      let customCert = CertificateManager.shared.getSignableCertificate(for: serialNumber) {
                self.context.overrideSigningCertificate = customCert
            }
        } else if let installedApp = self.context.installedApp, let serialNumber = installedApp.certificateSerialNumber {
            debugLog("[UpdateAppCertificateOperation] Certificate identity details omitted.")
            if let customCert = CertificateManager.shared.getSignableCertificate(for: serialNumber) {
                debugLog("[UpdateAppCertificateOperation] Certificate identity details omitted.")
                self.context.overrideSigningCertificate = customCert
            } else {
                debugLog("[UpdateAppCertificateOperation] Certificate identity details omitted.")
            }
        }
        
        self.setProgress(100)
    }
}
