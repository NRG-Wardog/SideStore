//
//  OnDeviceAnisetteManager.swift
//  SideStore
//
//  Created by Magesh K on 18/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Darwin
import AnisetteKit
import SideSign

public actor OnDeviceAnisetteManager {
    public static let shared = OnDeviceAnisetteManager()

    private let provider: AnisetteDataManager

    private init() {
        let baseDir: URL?
        if let sharedDir = FileManager.default.altstoreSharedDirectory {
            baseDir = sharedDir.appendingPathComponent(AppConstants.Anisette.hiddenBaseDirectoryName, isDirectory: true)
        } else {
            baseDir = FileManager.default.applicationSupportDirectory
                .appendingPathComponent(AppConstants.Anisette.appSupportSubdirectory, isDirectory: true)
                .appendingPathComponent(AppConstants.Anisette.hiddenBaseDirectoryName, isDirectory: true)
        }
        self.provider = AnisetteDataManager(baseDirectory: baseDir)
    }

    public nonisolated var baseAnisetteDirectory: URL? {
        provider.baseAnisetteDirectory
    }

    public nonisolated var librariesDirectory: URL? {
        provider.libsDir
    }

    public nonisolated var provisioningDirectory: URL? {
        provider.provisioningDir
    }

    public func isReady() async -> Bool {
        provider.isReady()
    }

    public func fetchAnisetteData() async throws -> ALTAnisetteData {
        debugLog("[OnDeviceAnisetteManager] [Fetch] Fetching on-device Anisette headers...")

        // DEBUG TEMPORARY: one value-owned trace for this invocation only.
        var debugTrace = V3TemporaryAnisetteTrace()
        var debugStep = V3TemporaryAnisetteTrace.Step.keychainRead
        var debugBlobState = V3AnisetteAttemptContext.BlobState.unknown
        do {
        debugTrace.record(step: debugStep, outcome: .started)
        // LC_ANISETTE_PAIR_PRECONDITION_V1
        let anisetteSnapshot = try await AnisetteConfigManager.shared.resolveAnisetteSnapshot()
        debugTrace.record(step: debugStep, outcome: .succeeded)
        debugTrace.record(step: .pairValidation, outcome: .succeeded)
        debugBlobState = anisetteSnapshot.adiBlob == nil ? .fresh : .existing
        debugTrace.record(step: .blobPresence, outcome: anisetteSnapshot.adiBlob == nil ? .skipped : .succeeded)
        let identifierUUID = anisetteSnapshot.identifier
        let existingAdiPbData = anisetteSnapshot.adiBlob

        debugStep = .requestHeaders
        debugTrace.record(step: debugStep, outcome: .started)
        let headers = await AnisetteConfigManager.shared.makeRequestHeaders()
        debugTrace.record(step: debugStep, outcome: .succeeded)

        let sourceURLString = UserDefaults.standard.menuAnisetteList.isEmpty ? AnisetteServersManager.defaultSource : UserDefaults.standard.menuAnisetteList
        let sourceURL = URL(string: sourceURLString) ?? AppConstants.Anisette.defaultODAMetadataURL
        let fallbackURL = AppConstants.Anisette.defaultODAMetadataURL

        let mode = AnisetteMode.remoteODA(sourceURL: sourceURL, fallbackURL: fallbackURL)

        debugStep = .primaryProvider
        debugTrace.record(step: debugStep, outcome: .started)
        let primary: (data: ALTAnisetteData, newAdiBlob: Data?)
        do {
            primary = try await provider.fetchAnisetteData(
                mode: mode, identifier: identifierUUID,
                existingAdiBlob: existingAdiPbData, headers: headers)
        } catch {
            debugTrace.record(step: debugStep, outcome: .failed)
            if let native = error as? AnisetteKit.AnisetteError,
               case .adiError(_, let description) = native {
                debugTrace.appendNative(errorDescription: description, scope: .primary)
            }
            return try await recoverVerifiedLegacyIdentity(
                after: error, snapshot: anisetteSnapshot, headers: headers,
                debugTrace: debugTrace)
        }
        debugTrace.record(step: debugStep, outcome: .succeeded)
        let (anisetteData, newAdiPb) = primary

        if let freshBlob = newAdiPb {
            debugStep = .freshBlobCommit
            debugTrace.record(step: debugStep, outcome: .started)
            try await AnisetteConfigManager.shared.commitAnisetteBlob(freshBlob, snapshot: anisetteSnapshot)
            debugTrace.record(step: debugStep, outcome: .succeeded)
            debugLog("[OnDeviceAnisetteManager] [Fetch] Fresh local provisioning completed -> saved new adi.pb (\(freshBlob.count) bytes) to Keychain")
        }

        debugLog("[OnDeviceAnisetteManager] [Fetch] SUCCESS: AnisetteData generated successfully.")
        return anisetteData
        } catch {
            let native = error as NSError
            if Task.isCancelled || error is CancellationError ||
                (native.domain == NSURLErrorDomain && native.code == NSURLErrorCancelled) { throw error }
            if error is V3AnisetteAttemptError { throw error }
            if debugStep == .keychainRead && error is LCAnisettePairError {
                debugTrace.record(step: .pairValidation, outcome: .failed)
            } else if debugStep != .primaryProvider {
                debugTrace.record(step: debugStep, outcome: .failed)
            }
            throw V3AnisetteAttemptError(underlying: error,
                context: V3AnisetteAttemptContext(blobState: debugBlobState,
                    recovery: .notAttempted, trace: debugTrace))
        }
    }
}

// LC_ANISETTE_VERIFIED_LEGACY_RECOVERY_V1
// Restore a preserved identity only after an isolated, OTP-only native proof.
// Neither candidate enumeration nor a failed probe changes Keychain bytes.
private enum LCAnisetteIsolatedProbe {
    enum LocalFailure: Error { case temporaryStorage }

    static func run(libraries: URL, identifier: UUID, blob: Data,
                    headers: AnisetteRequestHeaders) async throws
        -> (result: ALTAnisetteData, oneTimePassword: String, machineID: String) {
        try Task.checkCancellation()
        var pattern = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("LCAnisetteRecovery.XXXXXX").path.utf8CString)
        let root: URL = try pattern.withUnsafeMutableBufferPointer { buffer in
            guard let pointer = buffer.baseAddress, let made = mkdtemp(pointer) else {
                throw LocalFailure.temporaryStorage
            }
            return URL(fileURLWithPath: String(cString: made), isDirectory: true)
        }
        // Capture the outcome so cleanup runs exactly once, including after
        // cancellation. Only the exclusively-created root is removed.
        let outcome: Result<(ALTAnisetteData, String, String), Error>
        do {
            let raw = try await IsolatedAnisetteOTPProvider.getExistingHeaders(
                libDir: libraries, provisioningDir: root, identifier: identifier,
                existingBlob: blob, headers: headers)
            let data = try AnisetteDataManager.validateAndCreateAnisetteData(from: raw)
            guard let otp = raw[AnisetteConstants.Headers.oneTimePassword],
                  let mid = raw[AnisetteConstants.Headers.machineID] else {
                throw LCAnisetteRecoveryError.invalidNativeProof
            }
            outcome = .success((data, otp, mid))
        } catch { outcome = .failure(error) }
        do { try FileManager.default.removeItem(at: root) }
        catch { throw LocalFailure.temporaryStorage }
        try Task.checkCancellation()
        let (data, otp, mid) = try outcome.get()
        return (data, otp, mid)
    }
}

extension OnDeviceAnisetteManager {
    private func recoverVerifiedLegacyIdentity(
        after original: Error, snapshot: LCEmbeddedAnisetteSnapshot,
        headers: AnisetteRequestHeaders, debugTrace originalTrace: V3TemporaryAnisetteTrace
    ) async throws -> ALTAnisetteData {
        var debugTrace = originalTrace
        let blobState: V3AnisetteAttemptContext.BlobState = snapshot.adiBlob == nil ? .fresh : .existing
        func diagnosed(_ status: V3AnisetteAttemptContext.Recovery,
                       underlying: Error? = nil, probeError: Error? = nil) -> Error {
            var probeEvidence: V3AnisetteNativeEvidence?
            if let native = probeError as? AnisetteKit.AnisetteError,
               case .adiError(let code, let description) = native {
                probeEvidence = .capture(code: code, description: description)
            }
            return V3AnisetteAttemptError(underlying: underlying ?? original,
                context: V3AnisetteAttemptContext(blobState: blobState, recovery: status,
                    probeEvidence: probeEvidence, trace: debugTrace))
        }
        try Task.checkCancellation()
        if original is CancellationError { throw original }
        guard let native = original as? AnisetteKit.AnisetteError,
              case .adiError(let code, let description) = native else { throw original }
        guard LCAnisetteRecoveryPolicy.automaticRecoveryEnabled else {
            debugTrace.record(step: .currentProbe, outcome: .skipped)
            debugTrace.record(step: .legacyProbe, outcome: .skipped)
            debugTrace.record(step: .identityCommit, outcome: .skipped)
            throw diagnosed(.automaticRecoveryDisabled)
        }
        // Numeric equality alone does not identify the operation. Match the
        // pinned native OTP producer as well; setup/provisioning never recover.
        guard code == -45061,
              V3AnisetteNativeEvidence.capture(code: code, description: description).phase == .nativeOTP,
              let existingBlob = snapshot.adiBlob else { throw diagnosed(.notAttempted) }

        // Differential control: a clean VM may repair runtime/staging state
        // without changing the identity at all. Never infer a legacy mismatch
        // merely because a probe that also changes staging happens to succeed.
        let libraries = provider.libsDir
        var debugStep = V3TemporaryAnisetteTrace.Step.currentProbe
        debugTrace.record(step: debugStep, outcome: .started)
        do {
            let current = try await LCAnisetteIsolatedProbe.run(libraries: libraries,
                identifier: snapshot.identifier, blob: existingBlob, headers: headers)
            debugTrace.record(step: debugStep, outcome: .succeeded)
            debugStep = .currentProof
            debugTrace.record(step: debugStep, outcome: .started)
            try LCAnisetteRecoveryPolicy.validateNativeOTP(oneTimePassword: current.oneTimePassword,
                machineID: current.machineID)
            debugTrace.record(step: debugStep, outcome: .succeeded)
            try Task.checkCancellation()
            debugStep = .currentSnapshot
            debugTrace.record(step: debugStep, outcome: .started)
            try Keychain.shared.validateAnisetteSnapshot(snapshot)
            debugTrace.record(step: debugStep, outcome: .succeeded)
            try Task.checkCancellation()
            debugLog("[LC_ANISETTE_RECOVERY] outcome=isolated_current_pair")
            return current.result
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            debugTrace.record(step: debugStep, outcome: .failed)
            if let native = error as? AnisetteKit.AnisetteError,
               case .adiError(_, let description) = native {
                debugTrace.appendNative(errorDescription: description, scope: .current)
            }
            if let blocked = error as? LCAnisettePairError { throw diagnosed(.stateChanged, underlying: blocked) }
            if error is LCAnisetteIsolatedProbe.LocalFailure { throw diagnosed(.temporaryStorageUnavailable) }
            if error is LCAnisetteRecoveryError { throw diagnosed(.invalidNativeProof) }
            guard let control = error as? AnisetteKit.AnisetteError,
                  case .adiError(let controlCode, let controlDescription) = control,
                  controlCode == -45061,
                  V3AnisetteNativeEvidence.capture(code: controlCode, description: controlDescription).phase == .nativeOTP else {
                throw diagnosed(.currentProbeRejected, probeError: error)
            }
        }

        let candidate: LCAnisetteRecoveryCandidate
        debugStep = .legacyRead
        debugTrace.record(step: debugStep, outcome: .started)
        do {
            guard let found = try Keychain.shared.anisetteRecoveryCandidate(for: snapshot) else {
                debugTrace.record(step: debugStep, outcome: .succeeded)
                debugTrace.record(step: .legacyCandidate, outcome: .skipped)
                throw diagnosed(.noLegacyCandidate)
            }
            candidate = found
            debugTrace.record(step: debugStep, outcome: .succeeded)
            debugTrace.record(step: .legacyCandidate, outcome: .succeeded)
        } catch let failure as LCAnisetteRecoveryError {
            debugTrace.record(step: .legacyCandidate, outcome: .failed)
            switch failure {
            case .ambiguousLegacyIdentity: throw diagnosed(.ambiguousLegacyIdentity)
            case .legacyBlobMismatch: throw diagnosed(.legacyBlobMismatch)
            case .invalidLegacyPair: throw diagnosed(.invalidLegacyPair)
            case .invalidNativeProof: throw diagnosed(.invalidNativeProof)
            case .automaticRecoveryDisabled: throw diagnosed(.automaticRecoveryDisabled)
            }
        } catch let blocked as LCAnisettePairError {
            debugTrace.record(step: debugStep, outcome: .failed)
            throw diagnosed(.stateChanged, underlying: blocked)
        } catch let reported as V3AnisetteAttemptError { throw reported }
        catch {
            try Task.checkCancellation()
            debugTrace.record(step: debugStep, outcome: .failed)
            throw diagnosed(.legacyReadFailed)
        }

        let validated: (proof: LCAnisetteRecoveryProof, result: ALTAnisetteData)
        debugStep = .legacyProbe
        debugTrace.record(step: debugStep, outcome: .started)
        do {
            validated = try await candidate.validateNativeOTP { identifier, blob in
                let result = try await LCAnisetteIsolatedProbe.run(libraries: libraries,
                    identifier: identifier, blob: blob, headers: headers)
                debugTrace.record(step: .legacyProbe, outcome: .succeeded)
                debugStep = .legacyProof
                debugTrace.record(step: debugStep, outcome: .started)
                return result
            }
            debugTrace.record(step: debugStep, outcome: .succeeded)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            debugTrace.record(step: debugStep, outcome: .failed)
            if let native = error as? AnisetteKit.AnisetteError,
               case .adiError(_, let description) = native {
                debugTrace.appendNative(errorDescription: description, scope: .legacy)
            }
            if error is LCAnisetteIsolatedProbe.LocalFailure {
                throw diagnosed(.temporaryStorageUnavailable)
            }
            if error is LCAnisetteRecoveryError { throw diagnosed(.invalidNativeProof) }
            throw diagnosed(.probeRejected, probeError: error)
        }
        try Task.checkCancellation()
        debugStep = .identityCommit
        debugTrace.record(step: debugStep, outcome: .started)
        do {
            _ = try Keychain.shared.commitAnisetteRecovery(validated.proof)
            debugTrace.record(step: debugStep, outcome: .succeeded)
        }
        catch let blocked as LCAnisettePairError {
            debugTrace.record(step: debugStep, outcome: .failed)
            throw diagnosed(.stateChanged, underlying: blocked)
        } catch {
            try Task.checkCancellation()
            debugTrace.record(step: debugStep, outcome: .failed)
            throw diagnosed(.restoreFailed)
        }
        debugLog("[LC_ANISETTE_RECOVERY] outcome=verifiedLegacyIdentityRestored")
        return validated.result
    }
}
