import Foundation

// In-memory owned boundaries only. No URLSession, transport, native ADI or durable storage.
public struct AnisetteData: Sendable {
    let route: String
    var clientInfo = "synthetic-Mac-client"
    var diagnosticHeaderProvenance = FixtureProvenance()
    mutating func markDiagnosticCacheHit(age: TimeInterval, requestedClientInfo: String) {}
}
struct FixtureProvenance: Sendable { var context = FixtureProvenanceContext() }
struct FixtureProvenanceContext: Sendable { var generationBlobInput = ObservationTag.notObserved }
public typealias ALTAnisetteData = AnisetteData
public final class FakeSession: @unchecked Sendable { func invalidateAndCancel() {} }
enum ILoaderRemoteTransport { static func makeSession() -> FakeSession { FakeSession() } }
enum ObservationTag { case remote, cacheHit, provider, notObserved; static func classify(_ value: String) -> Self { .remote } }
struct AuthenticationProviderObservation {
    init(mode: ObservationTag, stage: ObservationTag, requestedClientInfoSource: ObservationTag,
         requestedClientInfoFamily: ObservationTag, adapter: ObservationTag, librarySelection: ObservationTag,
         libraryValidation: ObservationTag, requestedBlobInput: ObservationTag) {}
    static func selectedBranch(onDevice: Bool) -> Self {
        Self(mode: .remote, stage: .cacheHit, requestedClientInfoSource: .provider,
             requestedClientInfoFamily: .remote, adapter: .remote, librarySelection: .remote,
             libraryValidation: .notObserved, requestedBlobInput: .notObserved)
    }
}
final class AuthenticationDiagnosticTrace: @unchecked Sendable {
    @TaskLocal static var current: AuthenticationDiagnosticTrace?
    func beginProviderObservation(_ observation: AuthenticationProviderObservation) {}
}
final class LoginDiagnosticTrace: @unchecked Sendable { @TaskLocal static var current: LoginDiagnosticTrace? }
enum FixtureStage: String { case login, provisioning, accountFinalize, anisetteFetch, primaryProvider }
func v3LoginStage<T>(_ stage: FixtureStage, _ operation: () async throws -> T) async rethrows -> T {
    FixtureLog.shared.record("stage:" + stage.rawValue)
    return try await operation()
}
func v3AuthenticationPhase<T>(_ stage: FixtureStage, _ operation: () async throws -> T) async rethrows -> T {
    try await operation()
}
func debugLog(_ message: String) {}
protocol AnisetteServerHandler: Sendable {}
struct FixtureHandler: AnisetteServerHandler {
    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam { teams[0] }
}
extension UserDefaults { var useOnDeviceAnisette: Bool { true } }
final class OnDeviceAnisetteManager: @unchecked Sendable {
    static let shared = OnDeviceAnisetteManager()
    func fetchAnisetteData() async throws -> ALTAnisetteData {
        FixtureLog.shared.record("localFetch")
        return AnisetteData(route: "local")
    }
}
struct LCEmbeddedAuthenticationCandidate: Sendable {}
public struct LCEmbeddedAuthenticationSnapshot: Sendable {
    var appleIDEmailAddress: String? = "fixture@example.invalid"
    var appleIDAdsid: String? = "synthetic-dsid"
    var appleIDXcodeToken: String? = "synthetic-token"
    var isAuthenticated: Bool { appleIDAdsid != nil && appleIDXcodeToken != nil }
}
final class Keychain: @unchecked Sendable {
    static let shared = Keychain()
    private let lock = NSLock()
    private var stored = LCEmbeddedAuthenticationSnapshot()
    func authenticationSnapshot() throws -> LCEmbeddedAuthenticationSnapshot { lock.withLock { stored } }
    func embeddedAuthenticationFailure(_ error: Error) -> Error { error }
    func replace(_ value: LCEmbeddedAuthenticationSnapshot) { lock.withLock { stored = value } }
}
public struct ALTAppleAPISession: Sendable {
    let dsid: String
    let authToken: String
    let anisetteData: ALTAnisetteData
    let xcodeVersion: String
}
public struct ALTAccount: Sendable { let appleID: String }
public struct ALTTeam: Sendable { let account: ALTAccount; let route: String }
public struct ALTCertificate: Sendable {}
enum OperationError: Error, Equatable { case notAuthenticated, cancelled }
enum DeveloperPortalError: Error { case noTeams }
final class ALTAppleAPI: @unchecked Sendable {
    static let shared = ALTAppleAPI()
    func fetchTeams(for account: ALTAccount, session: ALTAppleAPISession) async throws -> [ALTTeam] {
        FixtureLog.shared.record("portal:" + session.anisetteData.route)
        return [ALTTeam(account: account, route: session.anisetteData.route)]
    }
}
final class AnisetteConfigManager: @unchecked Sendable {
    static let shared = AnisetteConfigManager()
    func resolvedXcodeVersion() async -> String {
        FixtureLog.shared.record("version")
        if let gate = FixtureHooks.versionGate { await gate.arriveAndWait() }
        return "synthetic-version"
    }
}
class FixtureOperationBase: @unchecked Sendable {
    func cancel() {}
    func execute(parentProgress: Progress?) async throws -> SignInResult { fatalError("not a concrete operation") }
}
final class FixtureLog: @unchecked Sendable {
    static let shared = FixtureLog()
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ value: String) { lock.withLock { events.append(value) } }
    func reset() { lock.withLock { events = [] } }
    var snapshot: [String] { lock.withLock { events } }
    func count(_ value: String) -> Int { snapshot.filter { $0 == value }.count }
}
actor FixtureGate {
    private var arrivals = 0
    private var open = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func arriveAndWait() async {
        arrivals += 1
        let ready = observers.filter { $0.0 <= arrivals }
        observers.removeAll { $0.0 <= arrivals }
        for (_, observer) in ready { observer.resume() }
        if !open { await withCheckedContinuation { blocked.append($0) } }
    }
    func waitForArrivals(_ count: Int) async {
        if arrivals < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }
    func release() {
        open = true
        let waiting = blocked; blocked = []
        for continuation in waiting { continuation.resume() }
    }
}
enum FixtureHooks { @TaskLocal static var versionGate: FixtureGate? }
struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure(message) }
}
func expectFailure<T>(_ operation: () async throws -> T, _ message: String,
                      matching predicate: (Error) -> Bool) async throws {
    do { _ = try await operation() }
    catch {
        try expect(predicate(error), message + ": unexpected error category")
        return
    }
    throw FixtureFailure(message)
}
func makeContext(_ route: String, fail: Bool = false) -> ILoaderRemoteAuthenticationContext {
    ILoaderRemoteAuthenticationContext(canceller: { FixtureLog.shared.record("invalidate:" + route) }, fetcher: { _ in
        FixtureLog.shared.record("remoteFetch:" + route)
        if fail { throw ILoaderRemoteError.invalidResponse }
        return AnisetteData(route: route)
    })
}
func syntheticSession(_ route: String) -> ALTAppleAPISession {
    ALTAppleAPISession(dsid: "synthetic-dsid", authToken: "synthetic-token",
                      anisetteData: AnisetteData(route: route), xcodeVersion: "synthetic-version")
}
