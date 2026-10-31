//
//  Contexts.swift
//  AltStore
//
//  Created by Riley Testut on 6/20/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//


import Foundation
import CoreData
import Network
import SideSign


enum AlternateIconMode {
    case preserve
    case set(URL)
    case remove
}

fileprivate struct OperationStepItem {
    let step: any OperationStep
    let weight: Int64
    let maxReuse: Int
    let resetProgress: Bool
}

protocol WeightedOperationContext: AnyObject {
    func weightForFirstOccurrence(of step: some OperationStep) -> Int64?
    func weight(for step: some OperationStep, occurrenceNumber: Int) -> Int64?
    func consumeWeight(for step: some OperationStep) throws -> Int64
    func attachProgressSlot(for step: some OperationStep, childProgress: Progress, parentProgress: Progress) throws -> Bool
}

class OperationContext: WeightedOperationContext
{
    var error: Error?
    var dbBackgroundContext: NSManagedObjectContext
    var operationStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    private var stepItems: [OperationStepItem]
    private var currentIndex = 0
    private var remainingReuses: [Int: Int] = [:]
    private var stepProgressSlots: [Int: Progress] = [:]

    fileprivate init(stepItems: [OperationStepItem] = [], error: Error? = nil, dbBackgroundContext: NSManagedObjectContext)
    {
        self.stepItems = stepItems
        self.error = error
        self.dbBackgroundContext = dbBackgroundContext
        self.operationStartTime = CFAbsoluteTimeGetCurrent()
    }

    fileprivate init(context: OperationContext)
    {
        self.stepItems = context.stepItems
        self.currentIndex = context.currentIndex
        self.error = context.error
        self.dbBackgroundContext = context.dbBackgroundContext
        self.remainingReuses = context.remainingReuses
        self.stepProgressSlots = context.stepProgressSlots
        self.operationStartTime = context.operationStartTime
    }

    func weightForFirstOccurrence(of step: some OperationStep) -> Int64? {
        weight(for: step, occurrenceNumber: 1)
    }

    func weight(for step: some OperationStep, occurrenceNumber: Int) -> Int64? {
        guard let target = (step as Any) as? AnyHashable else {
            debugLog("[OperationContext] Failed to cast step '\(step)' to AnyHashable")
            return nil
        }
        var matchCount = 0
        for item in stepItems {
            if let itemTarget = (item.step as Any) as? AnyHashable, itemTarget == target {
                matchCount += 1
                if matchCount == occurrenceNumber {
                    return item.weight
                }
            }
        }
        verboseLog("[OperationContext] Weight not found for step '\(step)' (occurrence \(occurrenceNumber))")
        return nil
    }

    private func findIndex(for step: some OperationStep) -> Int? {
        guard let target = (step as Any) as? AnyHashable else { return nil }
        return stepItems.indices[currentIndex...].first(where: {
            guard let itemTarget = (stepItems[$0].step as Any) as? AnyHashable else { return false }
            return itemTarget == target
        })
    }

    @discardableResult
    func consumeWeight(for step: some OperationStep) throws -> Int64 {
        guard let index = findIndex(for: step) else {
            debugLog("[OperationContext] Failed to consume weight for step '\(step)' from index \(currentIndex)")
            throw OperationError.invalidParameters("Missing progress weight for step '\(step)' in steps list")
        }
        
        let item = stepItems[index]
        guard item.maxReuse > 0 else {
            debugLog("[OperationContext] Invalid maxReuse (\(item.maxReuse)) for step '\(step)'")
            throw OperationError.invalidParameters("Invalid maxReuse (\(item.maxReuse)) for step '\(step)' in steps list")
        }
        
        let remaining: Int
        if let existing = remainingReuses[index] {
            remaining = existing
        } else {
            remaining = item.maxReuse
            remainingReuses[index] = remaining
        }
        
        if remaining > 1 {
            remainingReuses[index] = remaining - 1
            return item.weight
        } else {
            // remaining is 1. Clear it completely from the map and advance currentIndex.
            remainingReuses[index] = nil
            currentIndex = index + 1
            purgeCompletedProgressSlots()
            return item.weight
        }
    }

    func attachProgressSlot(for step: some OperationStep, childProgress: Progress, parentProgress: Progress) throws -> Bool {
        guard let index = findIndex(for: step) else { return false }
        let item = stepItems[index]
        guard item.resetProgress else { return false }
        
        let slot: Progress
        if let existing = stepProgressSlots[index] {
            slot = existing
        } else {
            slot = Progress.discreteProgress(totalUnitCount: childProgress.totalUnitCount)
            parentProgress.addChild(slot, withPendingUnitCount: item.weight)
            stepProgressSlots[index] = slot
        }
        
        slot.completedUnitCount = 0
        slot.addChild(childProgress, withPendingUnitCount: childProgress.totalUnitCount)
        try consumeWeight(for: step)
        return true
    }

    private func purgeCompletedProgressSlots() {
        for slotIndex in stepProgressSlots.keys where slotIndex < currentIndex {
            stepProgressSlots[slotIndex] = nil
        }
    }
}

class StandaloneOperationContext: OperationContext
{
    let steps: [StandaloneExecutionStep]

    init(steps: [StandaloneExecutionStep], error: Error? = nil, dbBackgroundContext: NSManagedObjectContext)
    {
        self.steps = steps
        super.init(stepItems: steps.map { 
                OperationStepItem(
                    step: $0.step, 
                    weight: $0.weight, 
                    maxReuse: $0.maxReuse, 
                    resetProgress: $0.resetProgress
                ) 
            }, 
            error: error, 
            dbBackgroundContext: dbBackgroundContext
        )
    }

    init(context: StandaloneOperationContext)
    {
        self.steps = context.steps
        super.init(context: context)
    }
}

class PipelineOperationContext: OperationContext
{
    let pipelineSteps: [PipelineExecutionStep]
    let handler: PipelineExecutionHandler

    init(
        pipelineSteps: [PipelineExecutionStep],
        handler: PipelineExecutionHandler,
        error: Error? = nil,
        dbBackgroundContext: NSManagedObjectContext
    ) {
        self.pipelineSteps = pipelineSteps
        self.handler = handler
        super.init(stepItems: pipelineSteps.map { 
                OperationStepItem(
                    step: $0.step, 
                    weight: $0.weight, 
                    maxReuse: 1, 
                    resetProgress: false
                ) 
            }, 
            error: error, 
            dbBackgroundContext: dbBackgroundContext
        )
    }

    init(context: PipelineOperationContext)
    {
        self.pipelineSteps = context.pipelineSteps
        self.handler = context.handler
        super.init(context: context)
    }
}

struct PendingProfileBatch {
    let bundleID: String
    let profiles: [Data]
    let app: InstalledApp?
    let certStatus: CertificateStatus?
}

final class SharedPipelineContext: @unchecked Sendable
{
    private let lock = NSLock()
    private var rawAppIDs: [ALTAppID]?
    private var rawAppGroups: [ALTAppGroup]?

    private var rawPendingProfiles: [String: PendingProfileBatch] = [:]
    private var rawHasInjectedProfiles: Bool = false

    var pendingProfiles: [String: PendingProfileBatch] {
        get { lock.withLock { rawPendingProfiles } }
        set { lock.withLock { rawPendingProfiles = newValue } }
    }

    var hasInjectedProfiles: Bool {
        get { lock.withLock { rawHasInjectedProfiles } }
        set { lock.withLock { rawHasInjectedProfiles = newValue } }
    }

    var appIDs: [ALTAppID]? {
        get { lock.withLock { rawAppIDs } }
        set { lock.withLock { rawAppIDs = newValue } }
    }

    var appGroups: [ALTAppGroup]? {
        get { lock.withLock { rawAppGroups } }
        set { lock.withLock { rawAppGroups = newValue } }
    }

    func appendAppID(_ appID: ALTAppID) {
        lock.withLock { rawAppIDs = (rawAppIDs ?? []) + [appID] }
    }

    func appendAppGroup(_ appGroup: ALTAppGroup) {
        lock.withLock { rawAppGroups = (rawAppGroups ?? []) + [appGroup] }
    }

    func addPendingProfileBatch(_ batch: PendingProfileBatch) {
        lock.withLock { rawPendingProfiles[batch.bundleID] = batch }
    }
}

class InstallAppOperationContext: PipelineOperationContext
{
    let bundleIdentifier: String
    var customBundleIdentifier: String?
    var customInfoPlistByBundleID: [String: [String: any Sendable]] = [:]
    var customEntitlementsByBundleID: [String: [String: any Sendable]] = [:]
    var isStoreUpdate: Bool = false
    var targetAppBundle: ALTApplication?

    var legacyReplacementBinding: V3LegacyReplacementBinding?

    var profileMutationAdmission: (() throws -> Void)?
    var readInstalledProvisioningProfiles: (() async throws -> [Data])?
    var verifiedRefreshCertificate: (serial: String, data: Data, expiry: Date)?
    var refreshVerification: V3RefreshVerification?
    var recordRefreshVerification: ((V3RefreshVerification) -> Void)?
    var provisioningProfiles: [String: ALTProvisioningProfile]?
    var appexBundleIds: [String: String]?
    var useMainProfile = false
    var isPreservationRefresh = false
    var preservationRefreshState: V3PreservationRefreshState?
    var validatedReuseMain = false
    var validatedReuseMainGeneration: String?
    // Historical acknowledged installation evidence, never live installed-state proof.
    var acknowledgedReuseMainIdentity: V3ValidatedReuseMainRegistry.AcknowledgedIdentity?
    var validateExtensionSigningCapabilities = false
    var originalExtensionBundleIdentifiers: [String: String] = [:]
    var previouslyReusedExtensionIdentifiers: Set<String> = []
    var isFinished = false
    var isCellularRefreshGroup: Bool = false
    var groupOperationsCount: Int = 1

    var overrideSigningCertificate: ALTCertificate?
    var overrideProvisioningProfile: ALTProvisioningProfile?
    let activeSigningCertificate: ALTCertificate?

    var targetSigningCertificate: ALTCertificate? {
        overrideSigningCertificate ?? activeSigningCertificate
    }

    var targetCertStatus: CertificateStatus?
    var appendTeamID: Bool = true

    let sharedContext: SharedPipelineContext

    var targetBundleIdentifier: String { customBundleIdentifier ?? bundleIdentifier }

    lazy var temporaryDirectory: URL = {
        let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        }
        catch { self.error = error }
        return temporaryDirectory
    }()

    var ipaURL: URL?
    var resignedAppBundle: ALTApplication?
    var installedApp: InstalledApp?
    var appBundleFingerprint: String?
    var releaseTrack: ReleaseTrack?
    var additionalEntitlements: [ALTEntitlement: any Sendable] = [:]
    
    var beginInstallationHandler: ((InstalledApp) -> Void)?

    var alternateIconMode: AlternateIconMode = .preserve

    var alternateIconURL: URL? {
        switch self.alternateIconMode {
        case .set(let url):
            return url
        case .preserve:
            if let installedApp = self.installedApp, installedApp.hasAlternateIcon {
                return installedApp.alternateIconURL
            }
            return nil
        case .remove:
            return nil
        }
    }

    // Explicit replacement has its own immutable consent/source binding. These
    // checks do not treat cached input as proof of the currently installed binary.
    func validateLegacyReplacementAdmission() async throws {
        guard let binding = legacyReplacementBinding else { return }
        try Task.checkCancellation()
        try profileMutationAdmission?()
        func checkLocalState() throws {
            guard handler.legacyReplacementBinding == binding,
                  bundleIdentifier == binding.originalBundleID,
                  customBundleIdentifier == binding.customBundleID,
                  !useMainProfile, !validatedReuseMain,
                  overrideProvisioningProfile == nil,
                  let certificate = targetSigningCertificate,
                  certificate.serialNumber == binding.certificateSerial,
                  certificate.x509.data == binding.certificateDER,
                  certificate.x509.expiryDate > Date() else {
                throw OperationError.invalidParameters("The confirmed replacement identity is no longer available.")
            }
        }
        try checkLocalState()
        try await handler.validateLegacyReplacementAdmission()
        try Task.checkCancellation()
        try profileMutationAdmission?()
        try checkLocalState()
    }

    func validateLegacyReplacementBundle(_ bundle: ALTApplication, signed: Bool) throws {
        guard let binding = legacyReplacementBinding else { return }
        let expectedMain = signed ? binding.resignedBundleID : binding.originalBundleID
        let expectedExtensions = Set(signed ? Array(binding.extensionIdentities.values) : Array(binding.extensionIdentities.keys))
        let actual = bundle.appExtensions.map { $0.bundleIdentifier }
        guard bundle.bundleIdentifier == expectedMain, actual.count == expectedExtensions.count,
              Set(actual) == expectedExtensions else {
            throw OperationError.invalidParameters("The replacement app or extension identity changed.")
        }
        if signed {
            for part in bundle.allAppBundles {
                guard let profile = part.provisioningProfile,
                      profile.bundleIdentifier == part.bundleIdentifier,
                      profile.teamIdentifier == binding.teamID,
                      profile.expirationDate > Date(),
                      profile.certificates.contains(where: { $0.serialNumber == binding.certificateSerial && $0.data == binding.certificateDER }),
                      let signedApplicationID = part.entitlements[ALTEntitlement.applicationIdentifier] as? String,
                      let profileApplicationID = profile.entitlements[ALTEntitlement.applicationIdentifier] as? String,
                      !signedApplicationID.isEmpty, signedApplicationID == profileApplicationID,
                      signedApplicationID.hasSuffix("." + part.bundleIdentifier),
                      signedApplicationID.count > part.bundleIdentifier.count + 1,
                      part.entitlements[ALTEntitlement(rawValue: "com.apple.developer.team-identifier")] as? String == binding.teamID,
                      let signedCertificate = CertificateManager.shared.getSigningCertificate(at: part.fileURL),
                      signedCertificate.serialNumber == binding.certificateSerial,
                      signedCertificate.data == binding.certificateDER else {
                    throw OperationError.invalidParameters("The signed replacement identity could not be verified.")
                }
            }
        }
    }

    func legacyReplacementProfileKey(originalID: String) throws -> String {
        guard let binding = legacyReplacementBinding else { return originalID }
        if originalID == binding.originalBundleID { return targetBundleIdentifier }
        guard binding.extensionIdentities[originalID] != nil,
              originalID.hasPrefix(binding.originalBundleID + ".") else {
            throw OperationError.invalidParameters("The replacement extension is not part of the confirmed input.")
        }
        return targetBundleIdentifier + originalID.dropFirst(binding.originalBundleID.count)
    }

    func validateLegacyReplacementProfiles(_ profiles: [String: ALTProvisioningProfile]) throws {
        guard let binding = legacyReplacementBinding else { return }
        var expected = [targetBundleIdentifier: binding.resignedBundleID]
        for (original, signed) in binding.extensionIdentities {
            expected[try legacyReplacementProfileKey(originalID: original)] = signed
        }
        guard Set(profiles.keys) == Set(expected.keys), Set(profiles.values.map { $0.uuid }).count == profiles.count else {
            throw OperationError.invalidParameters("Separate profiles are required for every replacement component.")
        }
        for (key, signedID) in expected {
            guard let profile = profiles[key], profile.bundleIdentifier == signedID,
                  profile.teamIdentifier == binding.teamID, profile.expirationDate > Date(),
                  profile.certificates.contains(where: { $0.serialNumber == binding.certificateSerial && $0.data == binding.certificateDER }) else {
                throw OperationError.invalidParameters("The replacement profile does not match the confirmed signing identity.")
            }
        }
    }

    // Non-nil when installing from a source.
    @AsyncManaged
    var appVersion: AppVersion?

    init(
        pipelineSteps: [PipelineExecutionStep],
        bundleIdentifier: String,
        dbBackgroundContext: NSManagedObjectContext,
        sharedContext: SharedPipelineContext,
        handler: PipelineExecutionHandler,
        additionalEntitlements: [ALTEntitlement: any Sendable] = [:],
        activeSigningCertificate: ALTCertificate? = nil,
        overrideSigningCertificate: ALTCertificate? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.sharedContext = sharedContext
        self.additionalEntitlements = additionalEntitlements
        self.activeSigningCertificate = activeSigningCertificate
        self.overrideSigningCertificate = overrideSigningCertificate
        super.init(
            pipelineSteps: pipelineSteps,
            handler: handler,
            error: nil,
            dbBackgroundContext: dbBackgroundContext
        )
    }
}

// Versioned opt-in is bound to a nonce sealed into the signed main Info.plist,
// not just a reusable profile UUID. Activation occurs only after confirmed
// ordinary-app installation. Host self-install remains on the legacy path.
enum V3ValidatedReuseMainRegistry {
    // V2 separates acknowledged signed output from the original source cache.
    // This is history of an installation we observed, not a claim that no external
    // installer has subsequently changed the device. Live preservation admission
    // must still reconcile the device's observed identity before profile mutation.
    struct AcknowledgedIdentity: Codable, Equatable, Sendable {
        let original: String
        let resigned: String
        let sourceFingerprint: String
        let sourceDigest: String
        let profileUUID: UUID
        let generation: String
        let teamID: String
        let certificateDER: Data
        let extensionIdentities: [String: String]
        let reusedExtensionIdentifiers: Set<String>

        var isWellFormed: Bool {
            !original.isEmpty && !resigned.isEmpty && !sourceFingerprint.isEmpty &&
            !sourceDigest.isEmpty && !teamID.isEmpty && !certificateDER.isEmpty &&
            UUID(uuidString: generation)?.uuidString == generation &&
            Set(extensionIdentities.values).count == extensionIdentities.count &&
            extensionIdentities.allSatisfy { originalID, signedID in
                originalID.hasPrefix(original + ".") && signedID.hasPrefix(resigned + ".")
            } && reusedExtensionIdentifiers == Set(extensionIdentities.values)
        }
    }

    private static let acknowledgedStorageKey = "v3.validated-reuse-main.acknowledged.v2"

    // Called only after native install acknowledgment. A failed/cancelled install
    // does not replace the previous record. A confirmed non-opt-in install clears
    // the prior opt-in association, including the old V1 entry.
    static func didAcknowledgeInstall(_ identity: AcknowledgedIdentity?, original: String, resigned: String) {
        lock.withLock {
            var records = acknowledgedRecords().filter { $0.original != original || $0.resigned != resigned }
            if let identity, identity.isWellFormed,
               identity.original == original, identity.resigned == resigned {
                records.append(identity)
            }
            if let data = try? JSONEncoder().encode(records) {
                UserDefaults.standard.set(data, forKey: acknowledgedStorageKey)
            } else {
                // Failed serialization must not leave stale evidence authorized.
                UserDefaults.standard.removeObject(forKey: acknowledgedStorageKey)
            }
            let base = prefix(original: original, resigned: resigned)
            let old = (UserDefaults.standard.stringArray(forKey: storageKey) ?? []).filter { !$0.hasPrefix(base) }
            UserDefaults.standard.set(old, forKey: storageKey)
        }
    }

    static func acknowledgedIdentity(original: String, resigned: String,
                                     sourceFingerprint: String?, sourceDigest: String?,
                                     teamID: String?, extensionIdentities: [String: String]) -> AcknowledgedIdentity? {
        guard let sourceFingerprint, let sourceDigest, let teamID else { return nil }
        return lock.withLock {
            let matches = acknowledgedRecords().filter { $0.original == original && $0.resigned == resigned }
            guard matches.count == 1, let identity = matches.first, identity.isWellFormed,
                  identity.sourceFingerprint == sourceFingerprint, identity.sourceDigest == sourceDigest,
                  identity.teamID == teamID, identity.extensionIdentities == extensionIdentities else { return nil }
            return identity
        }
    }

    private static func acknowledgedRecords() -> [AcknowledgedIdentity] {
        guard let data = UserDefaults.standard.data(forKey: acknowledgedStorageKey),
              let records = try? JSONDecoder().decode([AcknowledgedIdentity].self, from: data) else { return [] }
        return records
    }

    // V1 API is retained only for existing tests/old storage compatibility. No V1
    // record can authorize a V2 acknowledgedIdentity lookup or is auto-migrated.
    static let generationKey = "NRGValidatedReuseMainGenerationV1"
    private static let lock = NSLock()
    private static let storageKey = "v3.validated-reuse-main.v1"
    private static func prefix(original: String, resigned: String) -> String { original + "|" + resigned + "|" }
    private static func record(original: String, resigned: String, profileUUID: UUID?, generation: String?) -> String? {
        guard let profileUUID, let generation, UUID(uuidString: generation)?.uuidString == generation else { return nil }
        return prefix(original: original, resigned: resigned) + profileUUID.uuidString + "|" + generation
    }
    static func contains(original: String, resigned: String, profileUUID: UUID?, generation: String?) -> Bool {
        guard let record = record(original: original, resigned: resigned, profileUUID: profileUUID, generation: generation) else { return false }
        return lock.withLock { (UserDefaults.standard.stringArray(forKey: storageKey) ?? []).contains(record) }
    }
    static func hasAssociation(original: String, resigned: String) -> Bool {
        lock.withLock {
            let base = prefix(original: original, resigned: resigned)
            return (UserDefaults.standard.stringArray(forKey: storageKey) ?? []).contains { $0.hasPrefix(base) }
        }
    }
    static func didInstall(original: String, resigned: String, profileUUID: UUID?, generation: String?) {
        lock.withLock {
            let base = prefix(original: original, resigned: resigned)
            var records = (UserDefaults.standard.stringArray(forKey: storageKey) ?? []).filter { !$0.hasPrefix(base) }
            if let record = record(original: original, resigned: resigned, profileUUID: profileUUID, generation: generation) { records.append(record) }
            UserDefaults.standard.set(records, forKey: storageKey)
        }
    }
}
