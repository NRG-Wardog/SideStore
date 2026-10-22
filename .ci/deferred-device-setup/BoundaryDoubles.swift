import Foundation

struct ALTAccount { var appleID = "fixture@example.invalid"; var identifier = "synthetic-account" }
struct ALTTeam { var account: ALTAccount? = ALTAccount(); var identifier = "SYNTHETIC"; var name = "Fixture Team" }
struct ALTAppleAPISession { var dsid = "synthetic-account"; var authToken = "not-a-token" }
struct SyntheticX509 { var data: Data? = Data([1]); var organizationalUnit: String? = "SYNTHETIC" }
struct ALTCertificate { var x509 = SyntheticX509(); var data: Data? { x509.data }; var privateKey = Data([2]); var serialNumber = "fixture-certificate" }
struct ALTSigner { let team: ALTTeam; let certificate: ALTCertificate }
struct Credentials { var appleIDEmailAddress: String? = "fixture@example.invalid" }
struct ActiveCertificate { var certificate = ALTCertificate() }
struct ParsedCertificate { let subject = "SYNTHETIC"; let issuer = "SYNTHETIC" }
func parseCertificate(derData: Data) -> ParsedCertificate { ParsedCertificate() }
enum OperationError: Error { case cancelled }
struct V3PendingCertificateCreationError: Error { static let pending = Self() }
struct V3ProvisioningResumeUnavailableError: Error {}
struct SyntheticFailure: Error { let name: String; var requiresReconciliation = false; var portalSessionRejected = true }
enum CombinedFailure { enum SourceStep { case fetchTeams, saveAccount, fetchCertificate, activateCertificate, registerDevice, activateAccount } }
func v3AccountOperationFailure(_ error: Error, step: CombinedFailure.SourceStep) -> SyntheticFailure {
    (error as? SyntheticFailure) ?? SyntheticFailure(name: String(describing: step))
}
enum DiagnosticStage { case cleanup }
func v3LoginStage<T>(_ stage: DiagnosticStage, perform: () async throws -> T) async rethrows -> T { try await perform() }
enum V3AuthReadStampPolicy {
    static func mayReturn(capturedStamp: String, currentStamp: String, stable: Bool) -> Bool { stable && capturedStamp == currentStamp }
}
enum V3AuthIdentityBindingPolicy {
    static func mayUseTeam(sessionOwner: String?, teamOwner: String?) -> Bool { sessionOwner != nil && sessionOwner == teamOwner }
}
enum V3PendingCertificateKeyProof {
    static func matches(certificateDER: Data, privateKeyDER: Data) -> Bool { Boundary.keyMatches }
}
final class AuthManager {
    static let shared = AuthManager()
    var team: ALTTeam?
    var v3IdentityStamp = "synthetic-identity"
    var v3IdentityIsStable = true
    var authenticationSnapshot: Credentials? = Credentials()
    func v3CachedSessionMatchesCurrentRoute(_ session: ALTAppleAPISession?) -> Bool { Boundary.sessionMatches }
}
final class CertificateManager {
    static let shared = CertificateManager()
    var activeCertificate: ActiveCertificate? = ActiveCertificate()
    func setActiveCertificate(_ certificate: ALTCertificate) throws {
        Boundary.events.append("saveCertificate")
        if Boundary.failure == "certificateSave" { throw SyntheticFailure(name: "certificateSave") }
        activeCertificate = ActiveCertificate(certificate: certificate)
    }
    func v3CompletePendingCertificateIfStored(_ certificate: ALTCertificate) throws { Boundary.events.append("verifyCertificate") }
}
final class Keychain {
    static let shared = Keychain()
    func pendingCertificateCreation() throws -> Int? { nil }
}
final class FixtureHandler {
    enum Decision { case retry, cancel, skip }
    func resolveProvisioningError(_ error: SyntheticFailure) async -> Decision { Boundary.events.append("errorPrompt"); return .cancel }
    func complete() async { Boundary.events.append("handlerComplete") }
    func resolvePostAuth() async { Boundary.events.append("postAuth") }
}
class DeferredOperationBoundary {
    var isCancelled = false
    var v3RequireInteractiveCredentials = true
    var v3RequireFullProvisioning = true
    var v3ForceProvisioningRetry = false
    var v3ReauthenticateAppleID: String?
    var v3FinishPendingCertificateActivation = false
    var skipDeviceRegistration = false
    var skipCertificateProvisioning = false
    var skipResign = false
    var skipHowTos = false
    var requiresPostAuthFlow = true
    var v3DidDeferDeviceSetup = false
    var v3DidCompleteProvisioning = false
    let signInHandler = FixtureHandler()
    func debugLog(_ message: String) {}
    func verboseLog(_ message: String) {}
    func fetchTeam(for account: ALTAccount, session: ALTAppleAPISession) async throws -> ALTTeam {
        Boundary.events.append("team")
        if Boundary.failure == "team" { throw SyntheticFailure(name: "team") }
        return Boundary.team
    }
    func saveTeamAndAccount(_ team: ALTTeam, makeActive: Bool = false) async throws {
        Boundary.events.append(makeActive ? "activateChecked" : "saveInactive")
        if makeActive {
            if Boundary.failure == "activation" { throw SyntheticFailure(name: "activation") }
            if Boundary.cancelAtActivation { isCancelled = true }
            if Boundary.changeIdentityAtActivation { AuthManager.shared.v3IdentityStamp = "changed" }
        }
    }
    func fetchCertificate(for team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
        Boundary.events.append("certificate")
        if Boundary.failure == "certificate" { throw SyntheticFailure(name: "certificate") }
        return Boundary.certificate
    }
    func registerCurrentDevice(for team: ALTTeam, session: ALTAppleAPISession) async throws -> String {
        Boundary.events.append("register")
        if ["network", "udid", "portal"].contains(Boundary.failure) { throw SyntheticFailure(name: Boundary.failure) }
        return "synthetic-device"
    }
    func validateCodeSign(signer: ALTSigner, session: ALTAppleAPISession) async throws -> Bool {
        Boundary.events.append("resign"); return false
    }
}
enum PairingProtocol: String { case unknown, rppairing, lockdown }
class PairingBoundary { func pairingFileURL(for mode: PairingProtocol) -> URL { URL(fileURLWithPath: "/inert/" + mode.rawValue) } }
final class UserDefaults { static let standard = UserDefaults(); var isPairingReset = false }
final class FileManager {
    static let `default` = FileManager()
    func attributesOfItem(atPath path: String) throws -> [String: Int] {
        if Boundary.fileState == "missing" { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError) }
        if Boundary.fileState == "unreadable" { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
        return ["size": 0]
    }
}
final class Bundle {
    static let main = Bundle()
    func url(forResource: String, withExtension: String) -> URL? { Boundary.bundled ? URL(fileURLWithPath: "/inert/bundled") : nil }
    func object(forInfoDictionaryKey: String) -> Any? { Boundary.embedded }
}
enum Boundary {
    static var events: [String] = []
    static var account = ALTAccount()
    static var team = ALTTeam()
    static var session = ALTAppleAPISession()
    static var certificate = ALTCertificate()
    static var fileState = "missing"
    static var bundled = false
    static var embedded: Any?
    static var failure = ""
    static var keyMatches = true
    static var sessionMatches = true
    static var cancelAtActivation = false
    static var changeIdentityAtActivation = false
    static func reset() {
        events = []; account = ALTAccount(); team = ALTTeam(); session = ALTAppleAPISession(); certificate = ALTCertificate()
        fileState = "missing"; bundled = false; embedded = nil; failure = ""; keyMatches = true; sessionMatches = true
        cancelAtActivation = false; changeIdentityAtActivation = false
        UserDefaults.standard.isPairingReset = false
        AuthManager.shared.v3IdentityStamp = "synthetic-identity"; AuthManager.shared.v3IdentityIsStable = true
        AuthManager.shared.authenticationSnapshot = Credentials(); AuthManager.shared.team = nil
        CertificateManager.shared.activeCertificate = ActiveCertificate()
    }
}
