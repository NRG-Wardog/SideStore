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
        
        if let installedApp = self.context.installedApp, let serialNumber = installedApp.certificateSerialNumber {
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
