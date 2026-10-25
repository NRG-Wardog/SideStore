//
//  PipelineExecutionHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

protocol PipelineExecutionHandler: AnyObject, Sendable {
    var preflightChecksHandler: PreflightChecksHandler { get }
    var entitlementsReviewHandler: EntitlementsReviewHandler { get }
    var extensionRemovalHandler: ExtensionRemovalHandler { get }
    var unsupportedVersionHandler: UnsupportedVersionHandler { get }
    var installAppHandler: InstallAppHandler { get }
    var userCustomizationHandler: UserCustomizationHandler { get }
}



protocol PreflightChecksHandler: AnyObject, Sendable {
    func resolveBundleIDMismatch(targetID: String, activeEffectiveID: String) async -> Bool
    var isResignActive: Bool { get }
}

protocol EntitlementsReviewHandler: AnyObject, Sendable {
    func reviewPermissions(_ permissions: [ALTEntitlement], for app: AppProtocol, mode: PermissionReviewMode) async throws
}

enum ExtensionRemovalDecision: Sendable {
    case cancel
    case keepAll(useMainProfile: Bool)
    case keepAllValidatedReuseMain
    case removeAll
    case removeSelected(Set<ALTApplication>)
}

protocol ExtensionRemovalHandler: AnyObject, Sendable {
    func confirmSeparateExtensionProvisioning(reasonCodes: [String], extensionReasonCodes: [String: [String]], extensionCount: Int) async throws -> Bool
    func selectAppExtensionsToRemove(
        appBundle: ALTApplication,
        localAppExtensions: [ALTApplication],
        excessExtensions: Set<ALTApplication>
    ) async throws -> ExtensionRemovalDecision
}

extension ExtensionRemovalHandler {
    // A background/no-UI caller must not consume extra App IDs without consent.
    func confirmSeparateExtensionProvisioning(reasonCodes: [String], extensionReasonCodes: [String: [String]], extensionCount: Int) async throws -> Bool { false }
}

protocol UnsupportedVersionHandler: AnyObject, Sendable {
    func resolveUnsupportediOSVersion(errorDescription: String, appName: String, compatibleVersion: String) async throws -> Bool
}

protocol InstallAppHandler: AnyObject, Sendable {
    func requestBackgroundSuspension() async
    func suspendToHomeScreen() async
    func isAppInForeground() async -> Bool
}

enum AppGroupResolution: Sendable {
    case correctAndProceed(String)
    case keepOriginal(String)
}

enum ProfileCustomizationChoice: Sendable {
    case defaultProfile
    case profile(ALTProvisioningProfile)
}

protocol UserCustomizationHandler: AnyObject, Sendable {
    func resolveBundleIDOverride(initialBundleID: String) async throws -> (customID: String, appendTeamID: Bool)?
    func resolveInfoPlistCustomization(
        targets: [InfoPlistTarget],
        initialBundleID: String,
        appendTeamID: Bool,
        installedAppIdentities: [String: String],
        teamID: String
    ) async throws -> (modifiedPlists: [String: [String: any Sendable]], appendTeamID: Bool)?
    func resolveInfoPlistCustomization(
        initialPlist: [String: any Sendable],
        initialBundleID: String,
        appendTeamID: Bool,
        installedAppIdentities: [String: String],
        teamID: String
    ) async throws -> (modifiedPlist: [String: any Sendable], appendTeamID: Bool)?
    func resolveEntitlementsCustomization(
        targets: [EntitlementsTarget],
        teamType: ALTTeamType
    ) async throws -> [String: [String: any Sendable]]?
    func resolveEntitlementsCustomization(
        initialEntitlements: [String: any Sendable],
        bundleID: String,
        teamType: ALTTeamType
    ) async throws -> [String: any Sendable]?
    func resolveAppGroupMismatch(originalGroup: String, correctedGroup: String) async throws -> AppGroupResolution
    func resolveAppIconCustomization(appName: String) async throws -> URL?
    func resolveProvisioningProfileCustomization(appName: String, bundleID: String) async throws -> ProfileCustomizationChoice?
}


// The host has no reviewed IPC prompts for these new customization workflows yet.
// Do not turn an absent presenter into implicit approval or a changed identity.
extension UserCustomizationHandler {
    func resolveInfoPlistCustomization(
        targets: [InfoPlistTarget], initialBundleID: String, appendTeamID: Bool,
        installedAppIdentities: [String: String], teamID: String
    ) async throws -> (modifiedPlists: [String: [String: any Sendable]], appendTeamID: Bool)? {
        throw OperationError.invalidParameters("Info.plist customization requires a supported host prompt.")
    }

    func resolveInfoPlistCustomization(
        initialPlist: [String: any Sendable], initialBundleID: String, appendTeamID: Bool,
        installedAppIdentities: [String: String], teamID: String
    ) async throws -> (modifiedPlist: [String: any Sendable], appendTeamID: Bool)? {
        throw OperationError.invalidParameters("Info.plist customization requires a supported host prompt.")
    }

    func resolveEntitlementsCustomization(
        targets: [EntitlementsTarget], teamType: ALTTeamType
    ) async throws -> [String: [String: any Sendable]]? {
        throw OperationError.invalidParameters("Entitlement customization requires a supported host prompt.")
    }

    func resolveEntitlementsCustomization(
        initialEntitlements: [String: any Sendable], bundleID: String, teamType: ALTTeamType
    ) async throws -> [String: any Sendable]? {
        throw OperationError.invalidParameters("Entitlement customization requires a supported host prompt.")
    }

    func resolveAppIconCustomization(appName: String) async throws -> URL? {
        throw OperationError.invalidParameters("Icon customization requires a supported host prompt.")
    }

    func resolveProvisioningProfileCustomization(appName: String, bundleID: String) async throws -> ProfileCustomizationChoice? {
        throw OperationError.invalidParameters("Provisioning profile customization requires a supported host prompt.")
    }
}

// V3_REUSE_MAIN_EXPLANATION_BEGIN
/// Presentation only. Does not select profiles, alter capabilities or promise
/// observed portal savings. Unknown values never become arbitrary UI text.
enum V3ReuseMainExplanation {
    private static let reasons: [String: String] = [
        "extensionIdentifierOutsideContainer": "extension identifier is outside its container",
        "mainSigningIdentityUnavailable": "main signing identity is unavailable",
        "invalidExtensionApplicationIdentifier": "extension application identifier does not match",
        "debugEntitlementMismatch": "debug capability differs",
        "keychainGroupsMismatch": "keychain groups differ",
        "appGroupsMismatch": "app groups differ",
        "capabilitiesMismatch": "required capabilities differ",
        "mainProfileExpired": "main profile has expired",
        "customEntitlementOverridesRequireSeparateProfiles": "custom entitlement overrides require separate profiles"
    ]
    static func identifier(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !raw.isEmpty, raw.utf8.count <= 255,
              raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "[unrecognized extension identifier]"
        }
        return raw
    }
    static func reasonText(_ codes: [String]) -> String {
        let labels = Set(codes.map { reasons[$0] ?? "compatibility could not be established" })
        return labels.sorted().joined(separator: "; ")
    }
    static func offer(extensionCount: Int) -> String {
        let count = max(0, extensionCount)
        return "If all \(count) extensions pass compatibility checks, ReuseMain may avoid up to \(count) additional App IDs. If any extension fails, this version uses separate profiles for all \(count) extensions, avoiding 0 additional App IDs. Existing App IDs may already be registered; these are estimates, not measured savings."
    }
    static func fallback(reasonCodes: [String], extensionReasonCodes: [String: [String]], extensionCount: Int) -> String {
        let count = max(0, extensionCount)
        let details = extensionReasonCodes.keys.sorted().map { id in
            "• " + identifier(id) + ": " + reasonText(extensionReasonCodes[id] ?? [])
        }.joined(separator: "\n")
        let summary = reasonText(reasonCodes)
        let detailText = details.isEmpty ? summary : details
        return "Extensions that could not qualify for ReuseMain:\n" + detailText +
            "\n\nThis version falls back as a group: all \(count) extensions stay installed and use separate profiles. This fallback avoids 0 additional App IDs and may require up to \(count) separate App IDs (some may already exist). No extension is removed and no required capability is discarded. Continue with separate provisioning?"
    }
}
// V3_REUSE_MAIN_EXPLANATION_END
