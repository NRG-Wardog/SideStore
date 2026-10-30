// Synthetic provider and application boundaries. Identity, leases, coalescing and dispatch
// come from candidate source; these types never create a transport or native provider.
import Foundation

public struct AnisetteData: Sendable {
    let identity: Data
    let otp: Int
    var clientInfo: String
    var diagnosticHeaderProvenance = FixtureProvenance()
    mutating func markDiagnosticCacheHit(age: TimeInterval, requestedClientInfo: String) {}
}
public typealias ALTAnisetteData = AnisetteData
struct FixtureProvenance: Sendable { var context = FixtureProvenanceContext() }
struct FixtureProvenanceContext: Sendable { var generationBlobInput = ObservationTag.notObserved }
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
public final class FixtureRemoteSession: @unchecked Sendable { func invalidateAndCancel() {} }
enum ILoaderRemoteTransport { static func makeSession() -> FixtureRemoteSession { FixtureRemoteSession() } }
enum SideSign {
    enum AnisetteError: Error { case providerNotReady(String), invalidAnisetteData }
}
enum FixtureLoginStage { case primaryProvider }
func v3LoginStage<T>(_ stage: FixtureLoginStage, _ operation: () async throws -> T) async rethrows -> T {
    try await operation()
}
func debugLog(_ message: String) {}
protocol AnisetteServerHandler: Sendable {}
extension UserDefaults { var useOnDeviceAnisette: Bool { true } }
final class OnDeviceAnisetteManager: @unchecked Sendable {
    static let shared = OnDeviceAnisetteManager()
    func fetchAnisetteData() async throws -> ALTAnisetteData {
        FixtureProviderBackend.shared.noteLocalFetch()
        return AnisetteData(identity: Data(), otp: 0, clientInfo: "synthetic-local-profile")
    }
}

actor FixtureAsyncGate {
    private var arrivals = 0
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [(UUID, Int, CheckedContinuation<Void, Error>)] = []
    func arriveAndWait() async {
        arrivals += 1
        let ready = observers.filter { $0.1 <= arrivals }
        observers.removeAll { $0.1 <= arrivals }
        ready.forEach { $0.2.resume() }
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForArrivals(_ count: Int) async throws {
        if arrivals >= count { return }
        let id = UUID()
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self.expire(id)
        }
        try await withCheckedThrowingContinuation { observers.append((id, count, $0)) }
    }
    private func expire(_ id: UUID) {
        let expired = observers.filter { $0.0 == id }
        observers.removeAll { $0.0 == id }
        expired.forEach { $0.2.resume(throwing: FixtureFailure.assertion("synthetic gate timed out")) }
    }
    func release() {
        opened = true; let ready = waiters; waiters.removeAll(); ready.forEach { $0.resume() }
    }
}

final class FixtureProviderBackend: @unchecked Sendable {
    static let shared = FixtureProviderBackend()
    private let lock = NSLock()
    private var profileRevision = 1
    private var fetches: [ILoaderRemoteState] = []
    private var provisions = 0
    private var localFetches = 0
    private var gate: FixtureAsyncGate?
    func reset() {
        lock.withLock { profileRevision = 1; fetches = []; provisions = 0; localFetches = 0; gate = nil }
    }
    func setProfileRevision(_ revision: Int) { lock.withLock { profileRevision = revision } }
    func setGate(_ value: FixtureAsyncGate?) { lock.withLock { gate = value } }
    func noteLocalFetch() { lock.withLock { localFetches += 1 } }
    var observed: [ILoaderRemoteState] { lock.withLock { fetches } }
    var provisionCount: Int { lock.withLock { provisions } }
    var localCount: Int { lock.withLock { localFetches } }
    func profile() -> ILoaderRemoteProfile {
        lock.withLock {
            ILoaderRemoteProfile(endpoint: .macJkcoxson,
                clientInfo: "synthetic-validated-Mac-profile-\(profileRevision)", userAgent: "synthetic-user-agent")
        }
    }
    func fetch(_ state: ILoaderRemoteState) async throws -> (AnisetteData, ILoaderRemoteState) {
        let activeGate = lock.withLock { gate }
        if let activeGate { await activeGate.arriveAndWait() }
        try Task.checkCancellation()
        return lock.withLock {
            var next = state
            if next.adiPB == nil {
                provisions += 1
                next.adiPB = Data("synthetic-provisioned-blob".utf8).base64EncodedString()
            }
            fetches.append(next)
            return (AnisetteData(identity: next.identity, otp: fetches.count, clientInfo: next.profile.clientInfo), next)
        }
    }
}

public actor ILoaderRemoteAnisetteClient {
    public let endpoint: ILoaderRemoteEndpoint
    public init(endpoint: ILoaderRemoteEndpoint) { self.endpoint = endpoint }
    public nonisolated func invalidate() {}
    public func fetchProfile() async throws -> ILoaderRemoteProfile { FixtureProviderBackend.shared.profile() }
    public func fetch(state: ILoaderRemoteState, sim: String?) async throws -> (AnisetteData, ILoaderRemoteState) {
        try state.validated(for: state.profile)
        return try await FixtureProviderBackend.shared.fetch(state)
    }
}

extension Keychain {
    func authenticationSnapshot() throws -> LCEmbeddedAuthenticationSnapshot? {
        guard let values = try LCEmbeddedSharedKeychain.authenticationValuesLocked(keychain) else { return nil }
        func string(_ key: String) -> String? { values[key].flatMap { String(data: $0, encoding: .utf8) } }
        return LCEmbeddedAuthenticationSnapshot(appleIDEmailAddress: string("appleIDEmailAddress"),
            appleIDPassword: string("appleIDPassword"), appleIDAdsid: string("appleIDAdsid"),
            appleIDXcodeToken: string("appleIDXcodeToken"))
    }
    func embeddedAuthenticationFailure(_ error: Error) -> Error { error }
}

public struct ALTAppleAPISession: Sendable {
    let dsid: String
    let authToken: String
    let anisetteData: ALTAnisetteData
    let xcodeVersion: String
}
public struct ALTAccount: Sendable { let appleID: String }
public struct ALTTeam: Sendable {
    let identifier: String
    let account: ALTAccount?
    static var fixture: Self {
        Self(identifier: "synthetic-team", account: ALTAccount(appleID: fixtureCredentialsA.appleIDEmailAddress!))
    }
}
public struct ALTX509Certificate: Sendable { let identity: Data }
extension AuthManager {
    func getAuthenticatedTeam() async throws -> ALTTeam { .fixture }
}
final class ALTAppleAPI: @unchecked Sendable {
    static let shared = ALTAppleAPI()
    func fetchCertificates(for team: ALTTeam, session: ALTAppleAPISession) async throws -> [ALTX509Certificate] {
        try await FixturePortalBackend.shared.dispatch(session)
    }
}
final class FixturePortalBackend: @unchecked Sendable {
    static let shared = FixturePortalBackend()
    private let lock = NSLock()
    private var observed: [(ALTAppleAPISession, ILoaderRemoteAuthenticationContext?)] = []
    private var gate: FixtureAsyncGate?
    func reset() { lock.withLock { observed = []; gate = nil } }
    func setGate(_ value: FixtureAsyncGate?) { lock.withLock { gate = value } }
    var observations: [(ALTAppleAPISession, ILoaderRemoteAuthenticationContext?)] { lock.withLock { observed } }
    func dispatch(_ session: ALTAppleAPISession) async throws -> [ALTX509Certificate] {
        let context = ILoaderRemoteAuthentication.current
        let activeGate = lock.withLock { observed.append((session, context)); return gate }
        if let activeGate { await activeGate.arriveAndWait() }
        // The boundary intentionally permits a late result. Production awaitBound must reject it.
        return [ALTX509Certificate(identity: session.anisetteData.identity)]
    }
}
@MainActor final class V3HeadlessRuntime {
    static let shared = V3HeadlessRuntime()
    struct Auth { var hasActiveSession = false }
    var auth = Auth()
}
enum V3SideStoreServiceError: Error { case authRequired }
enum OperationError: Error { case notAuthenticated, unknownResult, cancelled; case invalidOperationContext(String) }
final class AnisetteConfigManager: @unchecked Sendable {
    static let shared = AnisetteConfigManager()
    func resolvedXcodeVersion() async -> String { "synthetic-version" }
}

struct AppOperation: Sendable {
    let bundleIdentifier: String
    static func refresh(_ app: InstalledApp) -> Self { Self(bundleIdentifier: app.bundleIdentifier) }
}
struct PipelineExecutionHandler: Sendable {}
final class NSManagedObjectContext: @unchecked Sendable {}
final class UIViewController: @unchecked Sendable {}
final class StandaloneOperationContext: @unchecked Sendable {
    var error: Error?
    let dbBackgroundContext = NSManagedObjectContext()
}
struct InstalledApp: Sendable {
    let anisette: AnisetteData
    let bundleIdentifier = "fixture.app"
    static var fixture: Self { Self(anisette: AnisetteData(identity: Data(), otp: 0, clientInfo: "synthetic")) }
}
final class RefreshGroup: @unchecked Sendable {
    // Observation-only external boundary; no readiness is synthesized.
    private(set) var boundTransportRunID: String?
    func bindTransportObservation(to runID: String) { boundTransportRunID = runID }
    var completionHandler: (([String: Result<InstalledApp, Error>]) -> Void)?
    var beginInstallationHandler: ((InstalledApp) -> Void)?
    var activeTask: Task<Void, Never>?
    var error: Error?
    let context: StandaloneOperationContext
    var results: [String: Result<InstalledApp, Error>] = [:]
    init(context: StandaloneOperationContext) { self.context = context }
    init(dbContext: NSManagedObjectContext) { self.context = StandaloneOperationContext() }
    func cancel() { activeTask?.cancel() }
}
enum StoreApp { static let altstoreAppID = "fixture.host" }
final class BackgroundRefreshAppsOperation: @unchecked Sendable {
    let context = StandaloneOperationContext()
    let refreshGroupLock = NSLock()
    var activeRefreshGroup: RefreshGroup?
    var isCancelled = false
    func debugLog(_ message: String) {}
    func persistAutomaticHostHandoff() {}
    func scheduleFinishedRefreshingNotification(for result: Result<[String: Result<InstalledApp, Error>], Error>) {}
    var persistedVerificationGroup: RefreshGroup?
    var persistedResultIDs: Set<String> = []
    var persistedAttemptedIDs: [String] = []
    var persistedRunID: String?
    func persistAutomaticRefreshVerification(results: [String: Result<InstalledApp, Error>], attemptedAppIDs: [String], group: RefreshGroup, runID: String) {
        persistedRunID = runID
        persistedVerificationGroup = group
        persistedResultIDs = Set(results.keys)
        persistedAttemptedIDs = attemptedAppIDs
    }
    func setProgress(_ value: Int) {}
}
enum FixturePipelineBoundary {
    private static let lock = NSLock()
    private static var gate: FixtureAsyncGate?
    static func setGate(_ value: FixtureAsyncGate?) { lock.withLock { gate = value } }
    static func waitIfConfigured() async {
        let current = lock.withLock { gate }
        if let current { await current.arriveAndWait() }
    }
}
actor FixturePipelineResult {
    private var result: Result<InstalledApp, Error>?
    private var waiter: CheckedContinuation<InstalledApp, Error>?
    func complete(_ result: Result<InstalledApp, Error>) {
        self.result = result
        waiter?.resume(with: result); waiter = nil
    }
    func value() async throws -> InstalledApp {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}
final class FixtureCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
func fixtureRunPipeline(onCompletion: (() -> Void)? = nil) async throws -> InstalledApp {
    let result = FixturePipelineResult()
    let counter = FixtureCallbackCounter()
    let group = PipelineRunner().performSingleOperation(AppOperation(bundleIdentifier: "fixture.app"),
        handler: PipelineExecutionHandler(), context: StandaloneOperationContext()) { value in
            counter.increment(); onCompletion?()
            Task { await result.complete(value) }
        }
    await group.activeTask?.value
    try fixtureCheck(counter.value == 1, "exactly one detached pipeline terminal callback")
    return try await result.value()
}
func fixtureRunAppManagerRefresh(onCompletion: (() -> Void)? = nil) async throws -> InstalledApp {
    let result = FixturePipelineResult()
    let counter = FixtureCallbackCounter()
    let group = RefreshGroup(context: StandaloneOperationContext())
    group.completionHandler = { values in
        counter.increment(); onCompletion?()
        let value = values["fixture.app"] ?? .failure(FixtureFailure.assertion("missing refresh result"))
        Task { await result.complete(value) }
    }
    AppManager.shared.refresh([.fixture], presentingViewController: nil, group: group)
    await group.activeTask?.value
    try fixtureCheck(counter.value == 1, "exactly one outer refresh terminal callback")
    return try await result.value()
}

func fixtureRuntimeReset() {
    V3RemoteRequestLeases.invalidateAll()
    V3RemoteRequestLeases.invalidateManualAttempts()
    fixtureReset()
    FixtureProviderBackend.shared.reset()
    FixturePortalBackend.shared.reset()
    FixturePipelineBoundary.setGate(nil)
    AuthManager.shared.v3AdvanceIdentityGeneration()
    AuthManager.shared.session = nil
}

func fixtureAsyncThrows(_ label: String, _ operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch is FixtureFailure { throw FixtureFailure.assertion(label + ": unexpected fixture boundary") }
    catch { return }
    throw FixtureFailure.assertion(label + ": expected failure")
}

// This pre-existing RemoteMac suite leaves the separate ODA route nil. Actual
// ODA staging/cancellation/commit gates execute in .ci/owned-oda, not this double.
enum OwnedODAAuthenticationError: Error { case conflictingRoutes }
enum OwnedODAAuthentication {
    @TaskLocal static var current: OwnedODAAuthenticationContext?
}
final class OwnedODAAuthenticationContext: @unchecked Sendable {
    func checkActive() throws { throw FixtureFailure.nativeBoundary }
    func invalidate() {}
    func fetch() async throws -> AnisetteData { throw FixtureFailure.nativeBoundary }
}
