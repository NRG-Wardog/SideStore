//
//  PipelineExecutor.swift
//  SideStore
//
//  Created by Magesh K on 3/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import CoreData
import SideSign

final class PipelineExecutor: @unchecked Sendable {
    static let shared = PipelineExecutor()
    private init() {}
    
    // Executes a flat list of `PipelineExecutionStep` items sequentially.
    // NOTE: Each pipeline step is an atomic operation unit and CANNOT execute another pipeline step
    //       nor trigger any standalone steps. Recursive step nesting or sub-pipeline invocation is strictly disallowed.
    @discardableResult
    func executePipeline(
        steps pipelineSteps: [PipelineExecutionStep],
        context: InstallAppOperationContext,
        operation: AppOperation,
        group: RefreshGroup,
        downloadingApp: AppProtocol,
        permissionsMode: PermissionReviewMode,
        operationProgress: Progress?
    ) async throws -> InstalledApp {
        var finalApp: InstalledApp?
        
        for pipelineStep in pipelineSteps {
            if let result = try await executeStep(
                pipelineStep.step,
                context: context,
                appOperation: operation,
                group: group,
                downloadingApp: downloadingApp,
                permissionsMode: permissionsMode,
                progress: operationProgress
            ) {
                finalApp = result
            }
        }
        
        guard let resultApp = finalApp ?? context.installedApp ?? (operation.app as? InstalledApp) else {
            throw OperationError.invalidParameters("Could not resolve installed app for '\(operation.app.name)'")
        }
        return resultApp
    }
    
    private func executeStep(
        _ step: PipelineStep,
        context: InstallAppOperationContext,
        appOperation: AppOperation,
        group: RefreshGroup,
        downloadingApp: AppProtocol,
        permissionsMode: PermissionReviewMode,
        progress: Progress?
    ) async throws -> InstalledApp? {
        var result: Any? = "()"
        var loggerType: any OperationLogging.Type
        
        defer {
            logOperationResult(result: result, loggerType: loggerType, operation: step)
        }

        // V3_PIPELINE_PHASE_REPORTING_V1: report the authoritative step before it runs.
        if let headlessHandler = context.handler as? V3HeadlessPipelineHandler {
            await headlessHandler.recordPipelinePhase(step,
                downloadUsesNetwork: downloadingApp.url?.isFileURL == false)
        }
        do {
            switch step {
            case .preflightChecks:
                loggerType = PreflightChecksOperation.self
                let handler = context.handler.preflightChecksHandler
                let step = try PreflightChecksOperation(operations: [appOperation],
                                                        handler: handler,
                                                        context: group.context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .userCustomization:
                loggerType = UserCustomizationOperation.self
                let step = try UserCustomizationOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .downloadApp:
                loggerType = DownloadAppOperation.self
                let downloadedAppURL = context.temporaryDirectory.appendingPathComponent("App.app")
                let step = try DownloadAppOperation(app: downloadingApp,
                                                    destinationURL: downloadedAppURL,
                                                    context: context)
                let downloadedAppBundle = try await step.execute(parentProgress: progress)
                context.targetAppBundle = downloadedAppBundle
                result = downloadedAppBundle
                return nil
                
            case .verifyApp:
                loggerType = VerifyAppOperation.self
                let step = try VerifyAppOperation(permissionsMode: permissionsMode, context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .cacheApp:
                loggerType = CacheAppOperation.self
                let step = try CacheAppOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .stageApp:
                loggerType = StageAppOperation.self
                let step = try StageAppOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .removeAppExtensions:
                loggerType = RemoveAppExtensionsOperation.self
                let localAppExtensions = (appOperation.app as? ALTApplication)?.appExtensions
                let step = try RemoveAppExtensionsOperation(context: context, localAppExtensions: localAppExtensions)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .fetchProvisioningProfiles:
                loggerType = FetchProvisioningProfilesOperation.self
                let step = try FetchProvisioningProfilesOperation(context: context)
                let profiles = try await step.execute(parentProgress: progress)
                context.provisioningProfiles = profiles
                result = profiles
                return nil
                
            case .prepareAppExtensionBundleIDs:
                loggerType = PrepareAppExtensionBundleIDsOperation.self
                let step = try PrepareAppExtensionBundleIDsOperation(context: context)
                try await step.execute(parentProgress: progress)
                return nil
                
            case .changeAppIcon:
                loggerType = ChangeAppIconOperation.self
                let step = try ChangeAppIconOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .resignApp:
                loggerType = ResignAppOperation.self
                let step = try ResignAppOperation(context: context)
                let resignedAppBundle = try await step.execute(parentProgress: progress)
                context.resignedAppBundle = resignedAppBundle
                result = resignedAppBundle
                return nil
                
            case .exportResignedIPA:
                loggerType = ExportResignedIpaOperation.self
                let step = try ExportResignedIpaOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .createIPA:
                loggerType = CreateIpaOperation.self
                let step = try CreateIpaOperation(context: context)
                let ipaURL = try await step.execute(parentProgress: progress)
                context.ipaURL = ipaURL
                result = ipaURL
                return nil
                
            case .sendApp:
                loggerType = SendAppOperation.self
                let step = try SendAppOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .installApp:
                loggerType = InstallAppOperation.self
                let step = try InstallAppOperation(context: context, app: appOperation.app)
                let installedApp = try await step.execute(parentProgress: progress)
                context.installedApp = installedApp
                result = installedApp
                if let index = UserDefaults.standard.legacySideloadedApps?.firstIndex(of: installedApp.bundleIdentifier) {
                    UserDefaults.standard.legacySideloadedApps?.remove(at: index)
                }
                return installedApp
                
            case .stageBackupApp:
                loggerType = StageBackupAppOperation.self
                let installedApp = appOperation.app as? InstalledApp
                let step = try StageBackupAppOperation(app: installedApp, context: context)
                let resultApp = try await step.execute(parentProgress: progress)
                context.installedApp = resultApp
                result = resultApp
                return resultApp
                
            case .refreshApp:
                loggerType = RefreshAppOperation.self
                let step = try RefreshAppOperation(context: context)
                let installedApp = try await step.execute(parentProgress: progress)
                context.installedApp = installedApp
                result = installedApp
                return installedApp
                
            case .backupAppData:
                loggerType = PerformBackupRestoreOperation.self
                let step = try PerformBackupRestoreOperation(action: .backup, context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .restoreAppData:
                loggerType = PerformBackupRestoreOperation.self
                let step = try PerformBackupRestoreOperation(action: .restore, context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .removeBackupData:
                loggerType = RemoveBackupDataOperation.self
                let step = try RemoveBackupDataOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .uninstallApp:
                loggerType = UninstallAppOperation.self
                let step = try UninstallAppOperation(context: context)
                let installedApp = try await step.execute(parentProgress: progress)
                context.installedApp = installedApp
                result = installedApp
                return installedApp

            case .markAppInactive:
                loggerType = MarkAppInactiveOperation.self
                let step = try MarkAppInactiveOperation(context: context)
                let installedApp = try await step.execute(parentProgress: progress)
                context.installedApp = installedApp
                result = installedApp
                return installedApp
                
            case .removeApp:
                loggerType = RemoveAppOperation.self
                let step = try RemoveAppOperation(context: context)
                let installedApp = try await step.execute(parentProgress: progress)
                context.installedApp = installedApp
                result = installedApp
                return installedApp
                
            case .deactivateApp:
                loggerType = DeactivateAppOperation.self
                let app = appOperation.app as? InstalledApp
                let step = try DeactivateAppOperation(app: app, context: context)
                let installedApp = try await step.execute(parentProgress: progress)
                context.installedApp = installedApp
                result = installedApp
                return installedApp
                
            case .cleanStagedApp:
                loggerType = CleanStagedAppOperation.self
                let step = try CleanStagedAppOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .verifyCertificate:
                loggerType = VerifyCertificateOperation.self
                var willResign = true
                if case .refresh = appOperation { willResign = false }
                let step = try VerifyCertificateOperation(context: context, willResign: willResign)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .updateAppCertificate:
                loggerType = UpdateAppCertificateOperation.self
                let step = try UpdateAppCertificateOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
                
            case .embedSigningCert:
                loggerType = EmbedSigningCertOperation.self
                let step = try EmbedSigningCertOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil

            case .cacheSigningCert:
                loggerType = CacheSigningCertOperation.self
                let step = try CacheSigningCertOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil

            case .cacheResignedMetadata:
                loggerType = CacheResignedMetadataOperation.self
                let step = try CacheResignedMetadataOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil

            case .patchInfoPlist:
                loggerType = PatchInfoPlistOperation.self
                let step = try PatchInfoPlistOperation(context: context)
                result = try await step.execute(parentProgress: progress)
                return nil
            }
        } catch {
            result = error
            if error is CancellationError { throw error }
            // A refresh boundary may already have a complete typed diagnosis.
            // Bridging it again would erase that evidence before manifest capture.
            if case .refresh = appOperation, error is CombinedFailure { throw error }
            // LC_STRUCTURED_FAILURE_V1: preserve step responsibility and the underlying error.
            var stage: String
            switch step {
            case .resignApp, .fetchProvisioningProfiles, .verifyCertificate: stage = "signing"
            case .sendApp, .installApp: stage = "installation"
            default: stage = "command"
            }
            var sourceStep: String?
            switch step {
            case .fetchProvisioningProfiles: sourceStep = "provisioningProfileFetch"
            case .verifyCertificate: sourceStep = "certificateValidation"
            case .resignApp: sourceStep = "localCodeSigning"
            default: break
            }
            if case .refresh = appOperation, sourceStep == nil {
                sourceStep = V3RefreshFailureBoundary.pipelineStep(step)?.sourceStep.rawValue
            }
            if let operationError = error as? OperationError, operationError == .notAuthenticated { stage = "authentication" }
            if let portalError = error as? DeveloperPortalError {
                switch portalError {
                case .incorrectCredentials, .appSpecificPasswordRequired, .requiresTwoFactorAuthentication,
                     .incorrectVerificationCode, .authenticationHandshakeFailed, .invalidAnisetteData,
                     .tooManyAttempts, .accountRepairRequired, .invalid2FAResponse: stage = "authentication"
                default: break
                }
            }
            var facts: [String: String] = [:]
            if stage == "signing" {
                facts["extension_count"] = String(context.targetAppBundle?.appExtensions.count ?? 0)
                facts["signing_certificate_present"] = context.targetSigningCertificate == nil ? "false" : "true"
                if let certificate = context.targetSigningCertificate {
                    facts["signing_certificate_serial_sha256"] = lcSigningHash(certificate.serialNumber)
                }
            }
            if case .refresh = appOperation {
                facts.merge(lcRefreshFailureFacts(error, sourceStep: sourceStep)) { existing, _ in existing }
            }
            throw lcStructuredSigningFailure(error, stage: stage, sourceStep: sourceStep, facts: facts)
        }
    }
    
    private func logOperationResult(result: Any?, loggerType: any OperationLogging.Type, operation: any OperationStep) {
        if UserDefaults.standard.isVerboseOperationsLoggingEnabled &&
           OperationsLoggingControl.isLoggingEnabled(for: loggerType.self)
        {
            let resultStatus = (result is Error) ? "FAILURE" : "SUCCESS"
            debugLog(
            """
            [PipelineExecutor] ====> OPERATION: .\(operation) completed with: \(resultStatus) <====
                • Component: '\(loggerType)'
                • Result: \(result ?? "nil")
                
            """
            )
        }
    }
}

// V3_REFRESH_FAILURE_BOUNDARIES_V1: observe responsibility at the actual
// instruction, not from a later progress label or a provider description.
// These diagnostics still need proper testing on a real refresh failure.
enum V3RefreshFailureBoundary: String, CaseIterable {
    case certificateSelection, refreshMetadataCache, refreshApplication
    case provisioningProfileInstallation, refreshRecordUpdate

    var stage: CombinedFailure.Stage {
        switch self {
        case .provisioningProfileInstallation: return .installation
        case .refreshRecordUpdate: return .persistence
        case .certificateSelection, .refreshMetadataCache, .refreshApplication: return .command
        }
    }

    var sourceStep: CombinedFailure.SourceStep {
        switch self {
        case .certificateSelection: return .certificateSelection
        case .refreshMetadataCache: return .refreshMetadataCache
        case .refreshApplication: return .refreshApplication
        case .provisioningProfileInstallation: return .provisioningProfileInstallation
        case .refreshRecordUpdate: return .refreshRecordUpdate
        }
    }

    static func pipelineStep(_ step: PipelineStep) -> V3RefreshFailureBoundary? {
        switch step {
        case .updateAppCertificate: return .certificateSelection
        case .cacheResignedMetadata: return .refreshMetadataCache
        case .refreshApp: return .refreshApplication
        default: return nil
        }
    }

    func preserving(_ error: Error) -> Error {
        if error is CancellationError || error is CombinedFailure { return error }
        // Existing finite native stage/source/cause markers take precedence.
        // The original error stays process-local; only allowlisted scalars are
        // serialized later by CombinedFailure.capture.
        return lcStructuredSigningFailure(error, stage: stage.rawValue,
            sourceStep: sourceStep.rawValue, facts: lcRefreshFailureFacts(error))
    }
}

// Capture the Swift enum before NSError bridging erases its case identity.
// Only the profile-fetch boundary may compare known local invalidParameters
// guards. Their associated text never leaves this function; unknown text stays
// unknown. Other operation payloads are never inspected.
func lcRefreshFailureFacts(_ error: Error, sourceStep: String? = nil) -> [String: String] {
    guard let operation = error as? OperationError else { return [:] }
    let kind: String
    switch operation {
    case .invalidParameters: kind = "invalidParameters"
    case .invalidOperationContext: kind = "invalidOperationContext"
    case .notAuthenticated: kind = "notAuthenticated"
    case .unknownResult: kind = "unknownResult"
    case .missingAppBundle: kind = "missingAppBundle"
    case .missingProvisioningProfile: kind = "missingProvisioningProfile"
    case .certificateExpired: kind = "certificateExpired"
    case .certificateRevoked: kind = "certificateRevoked"
    case .customCertificateExpired: kind = "customCertificateExpired"
    case .customCertificateRevoked: kind = "customCertificateRevoked"
    case .certificateChanged: kind = "certificateChanged"
    case .invalidApp: kind = "invalidApp"
    case .invalidPairingFile: kind = "invalidPairingFile"
    case .pairingNotComplete: kind = "pairingNotComplete"
    case .noDevice: kind = "noDevice"
    case .noConnection: kind = "noConnection"
    case .noVPN: kind = "noVPN"
    case .invalidVPN: kind = "invalidVPN"
    case .notReachable: kind = "notReachable"
    case .minimuxerNotStarted: kind = "minimuxerNotStarted"
    case .timedOut: kind = "timedOut"
    case .unknown: kind = "unknownOperation"
    default: kind = "otherOperation"
    }
    var facts = ["refresh_failure_kind": kind]
    // A finite, local pre-mutation observation. Never export the peer address
    // or classify arbitrary gateway text as a recoverable VPN condition.
    if sourceStep == "refreshReadiness" {
        if case .noVPN = operation { facts["refresh_readiness_reason"] = "vpnUnavailable" }
        if case .invalidVPN(let message) = operation {
            let prefix = "VPN tunnel iface is up and tunnel peer IP "
            let suffix = " is known, but TCP port poll failed — device may be unreachable on this interface"
            if message.hasPrefix(prefix), message.hasSuffix(suffix), message.utf8.count <= 512 {
                let peer = message.dropFirst(prefix.count).dropLast(suffix.count)
                let characters = "0123456789abcdefABCDEF:.%abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"
                if !peer.isEmpty, peer.utf8.count <= 128,
                   peer.allSatisfy({ characters.contains($0) }) {
                    facts["refresh_readiness_reason"] = "peerProbeFailed"
                }
            }
        }
    }
    guard sourceStep == "provisioningProfileFetch",
          case .invalidParameters(let message) = operation,
          message.utf8.count <= 1024 else { return facts }
    let reason: String?
    switch message {
    case "FetchProvisioningProfilesOperation: context.targetAppBundle is nil":
        reason = "missingTargetAppBundle"
    case "Cannot update features for unknown team type.":
        reason = "unknownTeamType"
    case "Missing progress weight for step 'fetchProvisioningProfiles' in steps list":
        reason = "missingProgressWeight"
    case "Missing PipelineStep mapping for FetchProvisioningProfilesOperation":
        reason = "missingPipelineStepMapping"
    default:
        let reusePrefix = "Invalid maxReuse ("
        let reuseSuffix = ") for step 'fetchProvisioningProfiles' in steps list"
        let groupPrefix = "Application group '"
        let groupSuffix = "' contains raw placeholder '$(APP_GROUP_IDENTIFIER)'."
        if message.hasPrefix(reusePrefix), message.hasSuffix(reuseSuffix) {
            let value = String(message.dropFirst(reusePrefix.count).dropLast(reuseSuffix.count))
            // Match only the original guard's canonical nonpositive Int.
            reason = Int(value).flatMap { $0 <= 0 && String($0) == value ? "invalidProgressReuse" : nil }
        } else if message.hasPrefix(groupPrefix), message.hasSuffix(groupSuffix) {
            let group = message.dropFirst(groupPrefix.count).dropLast(groupSuffix.count)
            let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-$()"
            // Full bounded template, not substring/provider-message matching.
            reason = group.utf8.count <= 256 && group.contains("$(APP_GROUP_IDENTIFIER)") &&
                group.allSatisfy({ allowed.contains($0) }) ? "unresolvedAppGroupPlaceholder" : nil
        } else { reason = nil }
    }
    if let reason { facts["local_precondition"] = reason }
    return facts
}

import CryptoKit
// LC_SIGNING_CAUSE_CLASSIFIER_V1: only typed upstream errors gain a semantic cause.
func lcSafeSigningCause(_ error: Error, portalResponse: Bool = false) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .networkConnectionLost: return "signingNetworkConnectionLost"
        case .timedOut: return "signingNetworkTimedOut"
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost:
            return "signingNetworkUnavailable"
        default: break
        }
    }
    let native = error as NSError
    if native.domain == NSURLErrorDomain {
        switch native.code {
        case NSURLErrorNetworkConnectionLost: return "signingNetworkConnectionLost"
        case NSURLErrorTimedOut: return "signingNetworkTimedOut"
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "signingNetworkUnavailable"
        default: break
        }
    }
    if let serverError = error as? ServerError {
        switch serverError {
        case .underlyingError: return portalResponse ? "developerPortalRejectedRequest" : "unknownSigningCause"
        case .badServerResponse, .invalidResponseFormat, .missingKey:
            return portalResponse ? "developerPortalInvalidResponse" : "unknownSigningCause"
        }
    }
    if let portalError = error as? DeveloperPortalError {
        switch portalError {
        case .maximumAppIDLimitReached: return "appIDLimitReached"
        case .provisioningProfileDoesNotExist: return "provisioningProfileUnavailable"
        case .certificateDoesNotExist: return "certificateUnavailable"
        default: break
        }
    }
    return "unknownSigningCause"
}

func lcSigningHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private final class LCSigningHTTPObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int?
    private var providerCode: String?
    private var resultCode: Int?
    func record(_ value: Int?, code: String?) {
        lock.lock(); defer { lock.unlock() }
        status = value.flatMap { (100...599).contains($0) ? $0 : nil }
        providerCode = SideSignPortalDiagnostics.safeProviderCode(code)
    }
    func recordResultCode(_ code: Int) {
        lock.lock(); defer { lock.unlock() }
        resultCode = code
    }
    func snapshot() -> (status: Int?, providerCode: String?, resultCode: Int?) {
        lock.lock(); defer { lock.unlock() }
        return (status, providerCode, resultCode)
    }
}

// Request facts are captured before calling the existing upstream API. No shared
// last-step state: parallel extension failures retain their own request identity.
func lcPortalSigningContext(teamID: String, generation: UInt64,
                            bundleID: String? = nil, features: [String: String]? = nil,
                            groupCount: Int? = nil, groupID: String? = nil, profileMode: String? = nil) -> [String: String] {
    var facts = ["account_binding": "verified", "team_binding": "verified",
                 "team_sha256": lcSigningHash(teamID), "session_generation": String(generation)]
    if let bundleID { facts["requested_bundle_sha256"] = lcSigningHash(bundleID) }
    if let features {
        facts["capability_count"] = String(features.count)
        facts["capabilities_sha256"] = lcSigningHash(features.sorted { $0.key < $1.key }
            .map { $0.key + "=" + $0.value }.joined(separator: "\n"))
        facts["capability_names"] = features.keys.filter { CombinedFailure.signingCapabilityNames.contains($0) }.sorted().joined(separator: ",")
        facts["enabled_capability_names"] = features.filter { CombinedFailure.signingCapabilityNames.contains($0.key) && $0.value == "true" }.keys.sorted().joined(separator: ",")
    }
    if let groupCount { facts["app_group_count"] = String(groupCount) }
    if let groupID { facts["requested_app_group_sha256"] = lcSigningHash(groupID) }
    if let profileMode {
        facts["profile_mode"] = profileMode
        // The team-profile endpoint chooses devices server-side. Do not claim
        // that a saved device or a UI certificate was explicitly sent to it.
        facts["device_registration"] = "unobserved"
    }
    return facts
}

func lcStructuredSigningFailure(_ error: Error, stage: String, sourceStep: String?,
                                facts: [String: String] = [:], portalResponse: Bool = false) -> NSError {
    let native = error as NSError
    var info: [String: Any] = ["LCStructuredFailureStageV1": stage,
        NSUnderlyingErrorKey: native, NSLocalizedDescriptionKey: "SideStore could not complete this pipeline step."]
    if let sourceStep { info["LCStructuredFailureSourceV1"] = sourceStep }
    var context = facts
    if stage == "signing" { info["LCStructuredFailureCauseV1"] = lcSafeSigningCause(error, portalResponse: portalResponse) }
    // Associated provider descriptions are not transport/stage evidence.
    // Reuse the wire boundary's existing typed-body guard for portal enums too.
    if error is DeveloperPortalError { context["typed_error"] = "sideSignDeveloperPortalError" }
    if let server = error as? ServerError {
        switch server {
        case .underlyingError(let code, _):
            context["typed_error"] = "sideSignServerReportedError"
            // -1 is SideSign's sentinel for a detail-only response, not an
            // observed numeric Apple result code. NSError's ordinal is never used.
            context["server_code"] = code == -1 ? "unknown" : String(code)
        case .badServerResponse: context["typed_error"] = "sideSignBadResponse"
        case .invalidResponseFormat: context["typed_error"] = "sideSignInvalidResponse"
        case .missingKey: context["typed_error"] = "sideSignMissingKey"
        }
        if context["http_status"] == nil { context["http_status"] = "unavailable" }
    }
    if let prior = native.userInfo["LCStructuredSigningContextV1"] as? [String: String] {
        context.merge(prior) { _, requestFact in requestFact }
    }
    for key in ["LCStructuredFailureStageV1", "LCStructuredFailureSourceV1", "LCStructuredFailureCauseV1"] {
        if let prior = native.userInfo[key] as? String { info[key] = prior }
    }
    if let safe = CombinedFailure.validatedSigningContext(context), !safe.isEmpty {
        info["LCStructuredSigningContextV1"] = safe
    }
    return NSError(domain: native.domain, code: native.code, userInfo: info)
}

func lcPortalSigningRequest<T>(sourceStep: String, facts: [String: String],
                               operation: () async throws -> T) async throws -> T {
    let observation = LCSigningHTTPObservation()
    do {
        return try await SideSignPortalDiagnostics.$responseObserver.withValue({ observation.record($0, code: $1) }) {
            try await SideSignPortalDiagnostics.$resultCodeObserver.withValue({ observation.recordResultCode($0) }) {
                try await operation()
            }
        }
    }
    catch let portal as DeveloperPortalError {
        // Only annotate the proven App ID capacity result; leave other typed
        // upstream business handling unchanged.
        guard sourceStep == "appIDRegistration",
              case .maximumAppIDLimitReached = portal else { throw portal }
        let response = observation.snapshot()
        var observed = facts
        observed["http_status"] = response.status.map { String($0) } ?? "unavailable"
        observed["provider_code"] = response.providerCode ?? "unavailable"
        observed["server_code"] = response.resultCode.map { String($0) } ?? "unknown"
        throw lcStructuredSigningFailure(portal, stage: "signing", sourceStep: sourceStep,
                                         facts: observed, portalResponse: true)
    }
    catch let server as ServerError {
        var observed = facts
        let response = observation.snapshot()
        observed["http_status"] = response.status.map { String($0) } ?? "unavailable"
        observed["provider_code"] = response.providerCode ?? "unavailable"
        // Keep business handling of other typed upstream errors unchanged.
        throw lcStructuredSigningFailure(server, stage: "signing", sourceStep: sourceStep,
                                         facts: observed, portalResponse: true)
    }
}

func lcProvisioningBundleRequest<T>(role: String, originalBundleID: String, preferredParentMatch: Bool,
                                    operation: () async throws -> T) async throws -> T {
    do { return try await operation() }
    catch {
        guard (error as? ServerError) != nil ||
              (error as NSError).userInfo["LCStructuredSigningContextV1"] != nil else { throw error }
        throw lcStructuredSigningFailure(error, stage: "signing", sourceStep: "provisioningProfileFetch",
            facts: ["provisioning_bundle_role": role,
                    "provisioning_bundle_sha256": lcSigningHash(originalBundleID),
                    "preferred_parent_id_match": String(preferredParentMatch)])
    }
}
