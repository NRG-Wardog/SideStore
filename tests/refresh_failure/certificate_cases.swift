// Inert service-call shells let the actual portalCertificates() implementation
// fail each request boundary independently without contacting a provider.
@MainActor enum FixturePortalState {
    static var failingAt: CombinedFailure.SourceStep?
    static var injectedError: Error = NSError(domain: "SECRET_PROVIDER_PAYLOAD_AND_PATH", code: 42)
    static var observed: [CombinedFailure.SourceStep] = []
    static func visit(_ step: CombinedFailure.SourceStep) throws {
        observed.append(step)
        if failingAt == step { throw injectedError }
    }
}
struct FixturePortalCertificate { let serialNumber: String }
@MainActor final class AuthManager {
    static let shared = AuthManager()
    func getAuthenticatedSession() async throws -> Int { try FixturePortalState.visit(.authenticate); return 1 }
    func getAuthenticatedTeam() async throws -> Int { try FixturePortalState.visit(.accountLookup); return 1 }
}
@MainActor final class DeveloperPortalProxy {
    static let shared = DeveloperPortalProxy()
    func fetchCertificates(team: Int) async throws -> [FixturePortalCertificate] {
        try FixturePortalState.visit(.fetchCertificate)
        return [FixturePortalCertificate(serialNumber: "fixture")]
    }
}
struct FixtureActiveCertificate { let certificate: FixturePortalCertificate }
@MainActor final class CertificateManager {
    static let shared = CertificateManager()
    var activeCertificate: FixtureActiveCertificate? = nil
}

@MainActor func certificatePortalBoundaryFixtureCases() async throws -> [(name: String, error: Error, expectedStep: CombinedFailure.SourceStep)] {
    let id = "00000000-0000-0000-0000-000000000001"
    let steps: [CombinedFailure.SourceStep] = [.authenticate, .accountLookup, .fetchCertificate]
    var rows: [(name: String, error: Error, expectedStep: CombinedFailure.SourceStep)] = []
    for (index, step) in steps.enumerated() {
        FixturePortalState.failingAt = step
        FixturePortalState.observed = []
        FixturePortalState.injectedError = NSError(domain: "SECRET_PROVIDER_PAYLOAD_AND_PATH", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "SECRET_PROVIDER_PAYLOAD_AND_PATH"])
        do { _ = try await FixtureCertificateCommands.portalCertificates(); preconditionFailure("Expected finite portal failure") }
        catch {
            let failure = CombinedFailure.capture(error, operation: "certPortalList", stage: .signing, id: id)
            precondition(failure.sourceStep == step)
            precondition(failure.stage == (step == .fetchCertificate ? .signing : .authentication))
            precondition(!failure.technicalDetails.contains("SECRET_PROVIDER_PAYLOAD_AND_PATH"))
            precondition(FixturePortalState.observed == Array(steps.prefix(index + 1)))
            rows.append(("certificate_" + step.rawValue, error, step))
        }
    }
    FixturePortalState.failingAt = nil
    FixturePortalState.observed = []
    let success = try await FixtureCertificateCommands.portalCertificates()
    precondition(success.count == 1 && FixturePortalState.observed == steps)
    FixturePortalState.failingAt = .authenticate
    FixturePortalState.injectedError = CancellationError()
    do { _ = try await FixtureCertificateCommands.portalCertificates(); preconditionFailure("Expected cancellation") }
    catch { precondition(error is CancellationError) }
    let known = CombinedFailure(operation: "signIn", stage: .authentication, code: .notReady,
        id: id, safeCause: .authSessionUnavailable, sourceStep: .anisetteFetch)
    FixturePortalState.injectedError = known
    do { _ = try await FixtureCertificateCommands.portalCertificates(); preconditionFailure("Expected typed failure") }
    catch {
        let preserved = error as! CombinedFailure
        precondition(preserved.stage == known.stage && preserved.sourceStep == known.sourceStep)
        precondition(preserved.safeCause == known.safeCause && preserved.correlationID == known.correlationID)
    }
    FixturePortalState.failingAt = nil
    print("CERTIFICATE_PORTAL_BOUNDARY_PASS")
    return rows
}
