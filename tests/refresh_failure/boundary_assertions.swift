// Executable assertions shared by standalone and comprehensive wire fixtures.
struct RefreshFailureBoundaryHarness {
    static let id = "00000000-0000-0000-0000-000000000001"
    static let secret = "SECRET_PROVIDER_PAYLOAD_AND_PATH"

    static func roundtrip(_ error: Error) throws -> CombinedFailure {
        let captured = CombinedFailure.capture(error, operation: "refresh", stage: .refreshVerification, id: id)
        let encoded = try PropertyListSerialization.data(fromPropertyList: captured.wire, format: .binary, options: 0)
        precondition(encoded.count <= 4096)
        let decoded = try PropertyListSerialization.propertyList(from: encoded, format: nil) as! [String: Any]
        let restored = CombinedFailure.decode(decoded, expectedID: id)!
        precondition(!restored.technicalDetails.contains(secret))
        precondition(!String(describing: restored.wire).contains(secret))
        precondition(!restored.message.contains(secret))
        precondition(CombinedFailure.decode(decoded, expectedID: UUID().uuidString) == nil)
        return restored
    }

    static func main() throws {
        precondition(V3RefreshFailureBoundary.pipelineStep(.updateAppCertificate) == .certificateSelection)
        precondition(V3RefreshFailureBoundary.pipelineStep(.cacheResignedMetadata) == .refreshMetadataCache)
        precondition(V3RefreshFailureBoundary.pipelineStep(.refreshApp) == .refreshApplication)
        precondition(V3RefreshFailureBoundary.pipelineStep(.verifyCertificate) == nil)
        precondition(V3RefreshFailureBoundary.pipelineStep(.fetchProvisioningProfiles) == nil)
        precondition(V3RefreshFailureBoundary.pipelineStep(.installApp) == nil)

        let privateNative = NSError(domain: secret, code: 42,
            userInfo: [NSLocalizedDescriptionKey: secret, "untrusted_payload": secret])
        for boundary in V3RefreshFailureBoundary.allCases {
            let marked = boundary.preserving(privateNative)
            // The production outer step wrapper must not replace the narrower
            // inner injection/update boundary with its generic command fallback.
            let outer = lcStructuredSigningFailure(marked, stage: "command", sourceStep: "refreshApplication")
            let failure = try roundtrip(outer)
            precondition(failure.sourceStep == boundary.sourceStep)
            precondition(failure.stage == boundary.stage)
            precondition(failure.safeCause == nil)
            precondition(failure.underlyingDomain == "redacted" && failure.underlyingCode == 0)
            precondition(failure.code == .failed)
        }

        let oldMarker = NSError(domain: "NSPOSIXErrorDomain", code: 13, userInfo: [
            NSLocalizedDescriptionKey: secret,
            "LCStructuredFailureStageV1": "pairing",
            "LCStructuredFailureSourceV1": "certificateValidation",
            "LCStructuredFailureCauseV1": "invalidPairingFile"])
        let preserved = try roundtrip(V3RefreshFailureBoundary.provisioningProfileInstallation.preserving(oldMarker))
        precondition(preserved.stage == .pairing && preserved.sourceStep == .certificateValidation)
        precondition(preserved.safeCause == .invalidPairingFile)
        precondition(preserved.underlyingDomain == "NSPOSIXErrorDomain" && preserved.underlyingCode == 13)

        let known = CombinedFailure(operation: "refresh", stage: .authentication, code: .notReady,
            id: id, safeCause: .authSessionUnavailable, sourceStep: .authenticate)
        let knownResult = V3RefreshFailureBoundary.provisioningProfileInstallation.preserving(known) as! CombinedFailure
        precondition(knownResult.stage == known.stage && knownResult.sourceStep == known.sourceStep)
        precondition(knownResult.safeCause == known.safeCause && knownResult.correlationID == id)
        let app = InstalledApp()
        let mappedKnown = getMappedError(for: .refresh(app), error: known) as! CombinedFailure
        precondition(mappedKnown.stage == known.stage && mappedKnown.sourceStep == known.sourceStep)
        precondition(mappedKnown.safeCause == known.safeCause && mappedKnown.correlationID == id)
        precondition(mappedKnown.code == known.code && mappedKnown.retryable == known.retryable)
        precondition(mappedKnown.signingContext == known.signingContext)
        // Unrelated operations still take the existing title-decoration route.
        precondition(!(getMappedError(for: .activate(app), error: known) is CombinedFailure))
        let mappedNative = getMappedError(for: .refresh(app), error:
            V3RefreshFailureBoundary.provisioningProfileInstallation.preserving(privateNative)) as NSError
        precondition(mappedNative is ALTWrappedError)
        precondition(mappedNative.userInfo[ALTLocalizedTitleErrorKey] as? String == "Failed to Refresh Fixture App")
        let mappedFailure = try roundtrip(mappedNative)
        precondition(mappedFailure.stage == .installation && mappedFailure.sourceStep == .provisioningProfileInstallation)
        precondition(mappedFailure.underlyingDomain == "redacted" && mappedFailure.underlyingCode == 0)
        let operationCases: [(OperationError, String)] = [
            (.invalidParameters(secret), "invalidParameters"),
            (.invalidOperationContext(secret), "invalidOperationContext"),
            (.notAuthenticated, "notAuthenticated"), (.unknownResult, "unknownResult"),
            (.missingAppBundle(reason: secret), "missingAppBundle"),
            (.missingProvisioningProfile(reason: secret), "missingProvisioningProfile"),
            (.certificateExpired(appName: secret), "certificateExpired"),
            (.certificateRevoked(appName: secret), "certificateRevoked"),
            (.customCertificateExpired(appName: secret, activeTeam: secret), "customCertificateExpired"),
            (.customCertificateRevoked(appName: secret, activeTeam: secret), "customCertificateRevoked"),
            (.certificateChanged(appName: secret), "certificateChanged"),
            (.invalidApp(reason: secret), "invalidApp"),
            (.invalidPairingFile(reason: secret), "invalidPairingFile"),
            (.pairingNotComplete(reason: secret), "pairingNotComplete"),
            (.noDevice(reason: secret), "noDevice"), (.noConnection(reason: secret), "noConnection"),
            (.noVPN(reason: secret), "noVPN"), (.invalidVPN(reason: secret), "invalidVPN"),
            (.notReachable(reason: secret), "notReachable"),
            (.minimuxerNotStarted(reason: secret), "minimuxerNotStarted"),
            (.timedOut, "timedOut"), (.unknown(failureReason: secret), "unknownOperation"),
            (.noInstalledApps, "otherOperation")]
        for (operation, kind) in operationCases {
            let facts = lcRefreshFailureFacts(operation)
            precondition(facts == ["refresh_failure_kind": kind])
            let wrapped = V3RefreshFailureBoundary.refreshApplication.preserving(operation)
            let failure = try roundtrip(wrapped)
            precondition(failure.signingContext["refresh_failure_kind"] == kind)
            precondition(failure.technicalDetails.contains("refresh_failure_kind=\(kind)"))
        }
        precondition(lcRefreshFailureFacts(privateNative).isEmpty)
        var injected = known.wire
        injected["signingContext"] = ["refresh_failure_kind": secret]
        precondition(CombinedFailure.decode(injected, expectedID: id) == nil)
        precondition(V3RefreshFailureBoundary.provisioningProfileInstallation.preserving(CancellationError()) is CancellationError)

        let cancelled = try roundtrip(V3RefreshFailureBoundary.provisioningProfileInstallation.preserving(URLError(.cancelled)))
        precondition(cancelled.code == .cancelled && cancelled.retryable == false)
        let cocoa = try roundtrip(V3RefreshFailureBoundary.refreshRecordUpdate.preserving(
            NSError(domain: NSCocoaErrorDomain, code: 134030, userInfo: [NSLocalizedDescriptionKey: secret])))
        precondition(cocoa.stage == .persistence && cocoa.sourceStep == .refreshRecordUpdate)
        precondition(cocoa.underlyingDomain == NSCocoaErrorDomain && cocoa.underlyingCode == 134030)
        print("REFRESH_FAILURE_BOUNDARY_PASS")
    }
}
