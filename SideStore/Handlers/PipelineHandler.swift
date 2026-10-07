//
//  PipelineHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit
import SideSign

final class PipelineHandler: PipelineExecutionHandler, 
                             PreflightChecksHandler, 
                             EntitlementsReviewHandler, 
                             ExtensionRemovalHandler, 
                             UnsupportedVersionHandler, 
                             InstallAppHandler, 
                             UserCustomizationHandler,
                             Sendable
{
    var preflightChecksHandler: PreflightChecksHandler { self }
    var entitlementsReviewHandler: EntitlementsReviewHandler { self }
    var extensionRemovalHandler: ExtensionRemovalHandler { self }
    var unsupportedVersionHandler: UnsupportedVersionHandler { self }
    var installAppHandler: InstallAppHandler { self }
    var userCustomizationHandler: UserCustomizationHandler { self }
    
    let isResignActive = false

    // V3_HEADLESS_PIPELINE_PRESENTER_REMOVED_V1: headless operations never request resign suspension.
    @MainActor
    func resolveBundleIDMismatch(targetID: String, activeEffectiveID: String) async -> Bool {
    // V3_HEADLESS_PIPELINE_UI_DECISIONS_V1: no UI context means fail closed.
    return false
}
    
    @MainActor
    func reviewPermissions(_ permissions: [ALTEntitlement], for app: AppProtocol, mode: PermissionReviewMode) async throws {
    // V3_HEADLESS_PIPELINE_UI_DECISIONS_V1: permission review cannot be approved headlessly.
    throw OperationError.invalidOperationContext("PipelineHandler: Cannot review permissions because presenting view controller is unavailable")
}
    
    @MainActor
    func selectAppExtensionsToRemove(
        appBundle: ALTApplication,
        localAppExtensions: [ALTApplication],
        excessExtensions: Set<ALTApplication>
    ) async throws -> ExtensionRemovalDecision {
        // V3_HEADLESS_PIPELINE_UI_DECISIONS_V1: keep all extensions without the review UI.
        return .keepAll(useMainProfile: false)
    }
    
    @MainActor
    func resolveUnsupportediOSVersion(errorDescription: String, appName: String, compatibleVersion: String) async throws -> Bool {
    // V3_HEADLESS_PIPELINE_UI_DECISIONS_V1: do not download an unrequested compatibility version.
    return false
}
    
    func requestBackgroundSuspension() async {
    // V3_HEADLESS_PIPELINE_UI_DECISIONS_V1: suspension is controlled by the host lifecycle.
}
    
    func suspendToHomeScreen() async {
        await CellularRefreshManager.shared.turnOnDataIfNeeded()
        await MainActor.run {
            _ = UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        }
    }
    
    func isAppInForeground() async -> Bool {
        await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
    }
    
    @MainActor
    func resolveBundleIDOverride(initialBundleID: String) async throws -> (customID: String, appendTeamID: Bool)? {
    // V3_HEADLESS_BUNDLE_ID_PROMPT_V1: the combined host owns the interactive prompt.
    return (initialBundleID, true)
}


    @MainActor
    func resolveAppGroupMismatch(originalGroup: String, correctedGroup: String) async throws -> AppGroupResolution {
    // V3_HEADLESS_PIPELINE_UI_DECISIONS_V1: preserve the validated corrected group without UI.
    return .correctAndProceed(correctedGroup)
}
}
