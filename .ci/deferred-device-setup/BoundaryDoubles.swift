import Foundation
import Security

struct ALTAccount { var appleID = "fixture@example.invalid"; var identifier = "synthetic-account" }
struct ALTTeam { var account: ALTAccount? = ALTAccount(); var identifier = "SYNTHETIC"; var name = "Fixture Team" }
struct ALTAppleAPISession { var dsid = "synthetic-account"; var authToken = "not-a-token" }
struct SyntheticX509 { var data: Data? = Boundary.certificateDER; var organizationalUnit: String? = "SYNTHETIC" }
struct ALTCertificate { var x509 = SyntheticX509(); var data: Data? { x509.data }; var privateKey = Boundary.privateKeyPEM; var serialNumber = "fixture-certificate" }
struct ALTSigner { let team: ALTTeam; let certificate: ALTCertificate }
struct Credentials { var appleIDEmailAddress: String? = "fixture@example.invalid"; var isAuthenticated = true }
struct ActiveCertificate { var certificate = ALTCertificate(); var p12Data = Boundary.syntheticP12; var password: String? = "" }
struct ParsedCertificate { let subject = "SYNTHETIC"; let issuer = "SYNTHETIC" }
func parseCertificate(derData: Data) -> ParsedCertificate { ParsedCertificate() }
enum OperationError: Error { case cancelled }
struct V3PendingCertificateCreationError: Error { static let pending = Self() }
struct V3ProvisioningResumeUnavailableError: Error {}
struct SyntheticFailure: Error { let name: String; var requiresReconciliation = false; var portalSessionRejected = true }
enum CombinedFailure {
    enum SourceStep { case fetchTeams, saveAccount, fetchCertificate, activateCertificate, registerDevice, activateAccount }
    enum Stage: String { case provisioning }
}
func v3AccountOperationFailure(_ error: Error, step: CombinedFailure.SourceStep) -> SyntheticFailure {
    (error as? SyntheticFailure) ?? SyntheticFailure(name: String(describing: step))
}
enum DiagnosticStage { case cleanup }
func v3LoginStage<T>(_ stage: DiagnosticStage, perform: () async throws -> T) async rethrows -> T { try await perform() }
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
            DatabaseManager.shared.account = team.account
            DatabaseManager.shared.team = team
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
    static var certificateDER = Data()
    static var privateKeyDER = Data()
    static var privateKeyPKCS8 = Data()
    static var privateKeyPEM = Data()
    static var wrongPrivateKeyDER = Data()
    static var syntheticP12 = Data()
    static var events: [String] = []
    static var account = ALTAccount()
    static var team = ALTTeam()
    static var session = ALTAppleAPISession()
    static var certificate = ALTCertificate()
    static var fileState = "missing"
    static var bundled = false
    static var embedded: Any?
    static var failure = ""
    static var sessionMatches = true
    static var cancelAtActivation = false
    static var changeIdentityAtActivation = false
    static func reset() {
        events = []; account = ALTAccount(); team = ALTTeam(); session = ALTAppleAPISession(); certificate = ALTCertificate()
        fileState = "missing"; bundled = false; embedded = nil; failure = ""; sessionMatches = true
        cancelAtActivation = false; changeIdentityAtActivation = false
        UserDefaults.standard.isPairingReset = false
        AuthManager.shared.v3IdentityStamp = "synthetic-identity"; AuthManager.shared.v3IdentityIsStable = true
        AuthManager.shared.authenticationSnapshot = Credentials(); AuthManager.shared.team = nil
        CertificateManager.shared.activeCertificate = ActiveCertificate()
        DatabaseManager.shared.account = nil; DatabaseManager.shared.team = nil
        V3HeadlessRuntime.shared.auth.hasActiveSession = false
    }
}

// Only synthetic in-memory state backs the extracted service guards. No service,
// Keychain, database, pairing transport or Apple account is contacted by this fixture.
enum ServiceError: Error { case notFound }
final class DatabaseManager {
    static let shared = DatabaseManager()
    var account: ALTAccount?
    var team: ALTTeam?
    func activeAccount() -> ALTAccount? { account }
    func activeTeam() -> ALTTeam? { team }
}
final class V3HeadlessRuntime {
    static let shared = V3HeadlessRuntime()
    final class Auth { var hasActiveSession = false }
    let auth = Auth()
}
struct FixtureSpan {
    enum Outcome { case succeeded }
    func finish(_ outcome: Outcome) {}
}
class ServiceBoundary {
    enum Mode { case interactive, resumeProvisioning }
    struct Session { var mode = Mode.interactive; var cancellationRequested = false; var prompt: String? }
    let sessionID = "00000000-0000-4000-8000-000000000001"
    var sessions = ["00000000-0000-4000-8000-000000000001": Session()]
    var ownsSession = true
    var resumableProvisioning: (String, String)?
    var terminal: [String: Any]?
    func ownsActiveSession(_ id: String) -> Bool { ownsSession && id == sessionID }
    func finish(id: String, response: [String: Any]) { terminal = response }
    func debugLog(_ message: String) {}
}

// Ephemeral fixture material is generated afresh inside the native test process.
// None is loaded from an account, written to a Keychain, exported to disk or logged.
enum SyntheticSigningIdentity {
    static func item(_ tag: UInt8, _ body: Data) -> Data {
        var length = body.count
        var encoded: [UInt8] = []
        if length < 128 { encoded = [UInt8(length)] }
        else {
            while length > 0 { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 }
            encoded.insert(0x80 | UInt8(encoded.count), at: 0)
        }
        return Data([tag] + encoded) + body
    }
    static func sequence(_ body: Data) -> Data { item(0x30, body) }
    static let rsaAlgorithm = sequence(Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00]))
    static let signingAlgorithm = sequence(Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00]))
    static func key() throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let value = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false
        ] as CFDictionary, &error) else { throw SyntheticFailure(name: "syntheticKeyGeneration") }
        return value
    }
    static func bytes(_ key: SecKey) throws -> Data {
        guard let value = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw SyntheticFailure(name: "syntheticKeyRepresentation")
        }
        return value
    }
    static func configure() throws {
        let privateKey = try key()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw SyntheticFailure(name: "syntheticPublicKey") }
        let privateDER = try bytes(privateKey)
        let publicDER = try bytes(publicKey)
        let name = sequence(item(0x31, sequence(Data([0x06,0x03,0x55,0x04,0x03]) + item(0x0c, Data("Owned Synthetic Fixture".utf8)))) +
            item(0x31, sequence(Data([0x06,0x03,0x55,0x04,0x0b]) + item(0x0c, Data("SYNTHETIC".utf8)))))
        let validity = sequence(item(0x17, Data("250101000000Z".utf8)) + item(0x17, Data("350101000000Z".utf8)))
        let publicInfo = sequence(rsaAlgorithm + item(0x03, Data([0]) + publicDER))
        let tbs = sequence(item(0xa0, Data([0x02,0x01,0x02])) + Data([0x02,0x01,0x01]) + signingAlgorithm + name + validity + name + publicInfo)
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data? else {
            throw SyntheticFailure(name: "syntheticCertificateSignature")
        }
        let certificateDER = sequence(tbs + signingAlgorithm + item(0x03, Data([0]) + signature))
        guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
            throw SyntheticFailure(name: "syntheticCertificateParse")
        }
        let pkcs8 = sequence(Data([0x02,0x01,0x00]) + rsaAlgorithm + item(0x04, privateDER))
        // A minimal unencrypted owned PFX. The real export adapter handles these
        // bytes unchanged; this fixture does not claim the host P12 parser ran.
        let keyBag = sequence(Data([0x06,0x0b,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x01]) + item(0xa0, pkcs8))
        let certBag = sequence(Data([0x06,0x0a,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x16,0x01]) + item(0xa0, item(0x04, certificateDER)))
        let safeCert = sequence(Data([0x06,0x0b,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x03]) + item(0xa0, certBag))
        func content(_ bytes: Data) -> Data {
            sequence(Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01]) + item(0xa0, item(0x04, bytes)))
        }
        Boundary.certificateDER = certificateDER
        Boundary.privateKeyDER = privateDER
        Boundary.privateKeyPKCS8 = pkcs8
        Boundary.privateKeyPEM = Data(("-----BEGIN RSA PRIVATE KEY-----\n" + privateDER.base64EncodedString() + "\n-----END RSA PRIVATE KEY-----\n").utf8)
        Boundary.wrongPrivateKeyDER = try bytes(key())
        Boundary.syntheticP12 = sequence(Data([0x02,0x01,0x03]) + content(sequence(content(sequence(keyBag + safeCert)))))
    }
}
