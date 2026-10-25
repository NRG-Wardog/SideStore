import Foundation

// Small host/service contract. The host never implements failover by replaying
// authBegin or changing global Anisette settings. A service must advertise this
// capability only after it implements the attempt isolation contract below.
enum V3DiagnosticProvider: String, CaseIterable, Equatable, Sendable {
    case remoteMac, onDevice, remoteServer

    var title: String {
        switch self {
        case .remoteMac: return "Remote Mac"
        case .onDevice: return "On-Device"
        case .remoteServer: return "Configured Remote Server"
        }
    }
}

struct V3DiagnosticProviderPlan: Equatable, Sendable {
    static let capability = "isolated-signin-sequence-v1"
    static let maximumProviders = 3
    let providers: [V3DiagnosticProvider]

    init?(_ raw: [String]) {
        guard !raw.isEmpty, raw.count <= Self.maximumProviders,
              Set(raw).count == raw.count else { return nil }
        let parsed = raw.compactMap(V3DiagnosticProvider.init(rawValue:))
        guard parsed.count == raw.count else { return nil }
        providers = parsed
    }

    var encoded: String { providers.map(\.rawValue).joined(separator: ",") }

    static func offered(kind: String, capability: String?, providers: [String]?) -> Self? {
        guard kind == "credentials", capability == Self.capability,
              let providers else { return nil }
        return Self(providers)
    }

    func selecting(_ ordered: [String]) -> Self? {
        guard let result = Self(ordered),
              result.providers.allSatisfy({ providers.contains($0) }) else { return nil }
        return result
    }
}

// Deliberately owns no credentials, tokens, verification codes, or provider URLs.
// The adapter must stop and join the previous task and invalidate its provider
// context before reporting quiescence. A timeout alone is not that evidence.
struct V3DiagnosticProviderSequence: Equatable, Sendable {
    enum Failure: String, Sendable {
        case providerUnavailable, transientNetwork, timedOut
        case invalidCredentials, accountRestricted, rateLimited, invalidCode
        case identityChanged, credentialStorage, unknown
    }
    enum State: Equatable, Sendable {
        case ready, attempting(Int), awaitingUser(Int), stopping(Int)
        case backoff(Int), succeeded(Int), exhausted, cancelled, stopped(Failure)
    }
    struct Attempt: Equatable, Sendable {
        let index: Int
        let generation: Int
        let provider: V3DiagnosticProvider
    }

    let plan: V3DiagnosticProviderPlan
    private(set) var state: State = .ready
    private(set) var results: [Failure?] = []
    private(set) var attempt: Attempt?
    private var generation = 0
    private var deadline: TimeInterval = 0
    private var retryAt: TimeInterval = 0
    private var challengeSeen = false

    init(plan: V3DiagnosticProviderPlan) { self.plan = plan }

    mutating func start(now: TimeInterval) -> Attempt? {
        guard state == .ready, now.isFinite else { return nil }
        return begin(index: 0, now: now)
    }

    private mutating func begin(index: Int, now: TimeInterval) -> Attempt {
        generation += 1
        let current = Attempt(index: index, generation: generation, provider: plan.providers[index])
        attempt = current
        challengeSeen = false
        deadline = now + 60
        state = .attempting(index)
        return current
    }

    mutating func needsUser(_ current: Attempt) {
        guard attempt == current, state == .attempting(current.index) else { return }
        challengeSeen = true
        state = .awaitingUser(current.index)
    }

    mutating func resumedByUser(_ current: Attempt, now: TimeInterval) {
        guard attempt == current, state == .awaitingUser(current.index), now.isFinite else { return }
        deadline = now + 60
        state = .attempting(current.index)
    }

    mutating func succeeded(_ current: Attempt) {
        guard attempt == current,
              state == .attempting(current.index) else { return }
        results.append(nil)
        state = .succeeded(current.index)
        attempt = nil
    }

    mutating func failed(_ current: Attempt, reason: Failure) {
        guard attempt == current,
              state == .attempting(current.index) || state == .awaitingUser(current.index) else { return }
        results.append(reason)
        // Any interactive challenge latches this attempt. Never rotate providers
        // after a 2FA challenge, even when its final request fails transiently.
        if challengeSeen || ![Failure.providerUnavailable, .transientNetwork, .timedOut].contains(reason) {
            state = .stopped(reason)
            attempt = nil
        } else {
            state = .stopping(current.index)
        }
    }

    mutating func checkTimeout(now: TimeInterval) -> Attempt? {
        guard now.isFinite, let current = attempt,
              state == .attempting(current.index), now >= deadline else { return nil }
        failed(current, reason: .timedOut)
        return current
    }

    mutating func previousAttemptStopped(_ current: Attempt, isolated: Bool,
                                        credentialsCommitted: Bool, now: TimeInterval) {
        guard attempt == current, state == .stopping(current.index), now.isFinite else { return }
        guard isolated, !credentialsCommitted else {
            state = .stopped(.identityChanged)
            attempt = nil
            return
        }
        guard current.index + 1 < plan.providers.count else {
            state = .exhausted
            attempt = nil
            return
        }
        retryAt = now + TimeInterval(2 * (current.index + 1))
        state = .backoff(current.index + 1)
        attempt = nil
    }

    mutating func continueAfterBackoff(now: TimeInterval) -> Attempt? {
        guard case .backoff(let index) = state, now.isFinite, now >= retryAt else { return nil }
        return begin(index: index, now: now)
    }

    mutating func cancel() {
        switch state {
        case .succeeded, .exhausted, .cancelled, .stopped: return
        default:
            state = .cancelled
            attempt = nil
        }
    }
}

// Route selection is task-local, including requests made by AuthManager. It
// neither overwrites the user's provider preference nor shares remote contexts.
enum V3DiagnosticProviderRoute {
    @TaskLocal static var current: V3DiagnosticProvider?
}

actor V3DiagnosticAttemptClock {
    private var last = ProcessInfo.processInfo.systemUptime
    private var elapsed: TimeInterval = 0
    private var paused = false
    private(set) var challengeSeen = false
    private(set) var appleRequestStarted = false
    func willAuthenticate() { appleRequestStarted = true }
    private func update() {
        let now = ProcessInfo.processInfo.systemUptime
        if !paused { elapsed += max(0, now - last) }
        last = now
    }
    func beginUserInput() { update(); paused = true; challengeSeen = true }
    func endUserInput() { update(); paused = false }
    func expired() -> Bool { update(); return elapsed >= 60 }
}

struct V3DiagnosticAttemptTimeout: Error {}
struct V3DiagnosticSequenceStopped: Error {}

// Advertisement is not native admission. Custom metadata must still supply a
// bounded, checksum-verified archive before any immutable library snapshot runs.
enum V3OwnedODASourceEligibility: String, Equatable, Sendable {
    case verifiedVendor, customIntegrityCheckRequired, unsupportedSource, missingStorage, lifecycleNotQualified
    // Exact trusted-startup and ownership qualification passed. Final packaging
    // still requires the final graph's native, context and identity suites.
    static let ownedLifecycleQualified = true
    var mayAttempt: Bool { self == .verifiedVendor || self == .customIntegrityCheckRequired }
    static func selectionMatches(captured: String, current: String) -> Bool { captured == current }
    static func evaluate(configuredSource: String, defaultSource: String,
                         ownedLifecycleQualified: Bool, hasBuiltInStorage: Bool) -> Self {
        guard ownedLifecycleQualified else { return .lifecycleNotQualified }
        if configuredSource.isEmpty || configuredSource == defaultSource {
            return hasBuiltInStorage ? .verifiedVendor : .missingStorage
        }
        guard let url = URL(string: configuredSource), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return .unsupportedSource }
        return .customIntegrityCheckRequired
    }
}
