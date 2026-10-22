import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func testOnboarding(_ rows: inout [String]) async throws {
    FixtureLog.shared.reset()
    let context = makeContext("remote-onboarding")
    let operation = SignInOperation(context: context)
    let result = try await operation.execute(parentProgress: nil)
    try expect(result.team.route == "remote-onboarding", "queued fetchTeams must use authenticated attempt identity")
    try expect(FixtureLog.shared.count("remoteFetch:remote-onboarding") == 1, "same context cache reused after auth")
    try expect(FixtureLog.shared.count("portal:remote-onboarding") == 2, "provisioning and finalization portal boundaries")
    try expect(FixtureLog.shared.count("finalize:remote-onboarding") == 1, "finalization stays remote")
    try expect(FixtureLog.shared.count("localFetch") == 0, "no local acquisition during approved onboarding")
    try expect(FixtureLog.shared.count("invalidate:remote-onboarding") == 1, "operation owns one final invalidation")
    try expect(ILoaderRemoteAuthentication.current == nil, "completed scope must not escape")
    rows.append("authenticated-session-to-queued-fetchTeams-and-finalization")
}

func testConcurrentRoutes(_ rows: inout [String]) async throws {
    FixtureLog.shared.reset()
    let first = makeContext("remote-first"), second = makeContext("remote-second")
    try expect(ObjectIdentifier(first) != ObjectIdentifier(second), "distinct live attempt identities")
    let gate = FixtureGate()
    try await FixtureHooks.$versionGate.withValue(gate) {
        let one = Task { try await ILoaderRemoteAuthentication.$current.withValue(first) { try await AuthManager.shared.getAuthenticatedSession() } }
        let two = Task { try await ILoaderRemoteAuthentication.$current.withValue(second) { try await AuthManager.shared.getAuthenticatedSession() } }
        let local = Task { try await ILoaderRemoteAuthentication.$current.withValue(nil) { try await AuthManager.shared.getAuthenticatedSession() } }
        await gate.waitForArrivals(3)
        await gate.release()
        let (a, b, c) = try await (one.value, two.value, local.value)
        try expect(a.anisetteData.route == "remote-first", "first attempt retains own provider")
        try expect(b.anisetteData.route == "remote-second", "second attempt cannot join first")
        try expect(c.anisetteData.route == "local", "background/default cannot join remote task")
    }
    try expect(FixtureLog.shared.count("version") == 3, "one producer per default/remote attempt partition")
    try expect(FixtureLog.shared.count("localFetch") == 1, "default producer remains default")
    try expect(FixtureLog.shared.count("remoteFetch:remote-first") == 1 && FixtureLog.shared.count("remoteFetch:remote-second") == 1, "distinct contexts fetched once")
    first.invalidate(); second.invalidate()
    rows.append("real-coalescer-default-and-two-attempts-isolation")
}

func testNilClearsAmbient(_ rows: inout [String]) async throws {
    FixtureLog.shared.reset()
    let unrelated = makeContext("unrelated-ambient")
    try await ILoaderRemoteAuthentication.$current.withValue(unrelated) {
        let result = try await SignInOperation(context: nil).fixturePhaseWrappers()
        try expect(result == "local", "nil operation clears inherited route at provisioning")
        try expect(ILoaderRemoteAuthentication.current === unrelated, "outer scope restored after wrappers")
    }
    try expect(FixtureLog.shared.count("portal:local") == 2 && FixtureLog.shared.count("finalize:local") == 1, "nil finalization stays local")
    try expect(FixtureLog.shared.count("remoteFetch:unrelated-ambient") == 0, "no unconsented ambient provider request")
    unrelated.invalidate()
    rows.append("nil-phase-wrappers-clear-unrelated-ambient-context")
}

func testRevokedDuringVersion(_ rows: inout [String]) async throws {
    FixtureLog.shared.reset()
    let context = makeContext("revoked")
    let selectedOperation = SignInOperation(context: context)
    let gate = FixtureGate()
    try await FixtureHooks.$versionGate.withValue(gate) {
        let task = Task { try await selectedOperation.execute(parentProgress: nil) }
        await gate.waitForArrivals(1)
        context.invalidate()
        await gate.release()
        try await expectFailure({ try await task.value }, "revoked attempt returned a session", matching: { ($0 as? ILoaderRemoteError)?.reasonCode == "consentRequired" })
    }
    try expect(FixtureLog.shared.count("sessionInstall") == 0, "revocation during version lookup must precede installation")
    try expect(FixtureLog.shared.count("portal:revoked") == 0 && FixtureLog.shared.count("localFetch") == 0, "revocation cannot dispatch or fall back")
    try expect(FixtureLog.shared.count("invalidate:revoked") == 1, "context remains a once-revoked sentinel")
    rows.append("revoked-during-version-await-no-install-no-dispatch-no-fallback")
}

func testCancelledWaiter(_ rows: inout [String]) async throws {
    FixtureLog.shared.reset()
    let context = makeContext("cancelled-waiter")
    let gate = FixtureGate()
    try await FixtureHooks.$versionGate.withValue(gate) {
        // Exercise the caller-side guard independently of operation invalidation.
        // The unstructured producer remains alive, but a cancelled waiter cannot use it.
        let task = Task {
            try await ILoaderRemoteAuthentication.$current.withValue(context) {
                let session = try await AuthManager.shared.getAuthenticatedSession()
                FixtureLog.shared.record("waiterReturned")
                return session
            }
        }
        await gate.waitForArrivals(1)
        task.cancel()
        await gate.release()
        try await expectFailure({ try await task.value }, "cancelled caller consumed queued result", matching: { $0 is CancellationError })
    }
    try expect(FixtureLog.shared.count("waiterReturned") == 0, "post-await cancellation check must reject value")
    try expect(FixtureLog.shared.count("localFetch") == 0, "cancelled waiter never falls back")
    context.invalidate()
    rows.append("cancelled-waiter-rejects-unstructured-coalescer-result")
}

func testIdentityGuard(_ rows: inout [String]) async throws {
    FixtureLog.shared.reset()
    let context = makeContext("stale-identity")
    let gate = FixtureGate()
    try await FixtureHooks.$versionGate.withValue(gate) {
        let task = Task {
            try await ILoaderRemoteAuthentication.$current.withValue(context) {
                try await DeveloperPortalProxy.shared.fetchTeams(for: ALTAccount(appleID: "fixture@example.invalid"))
            }
        }
        await gate.waitForArrivals(1)
        AuthManager.shared.v3AdvanceIdentityGeneration()
        await gate.release()
        try await expectFailure({ try await task.value }, "changed identity passed bound proxy", matching: { ($0 as? OperationError) == .notAuthenticated })
    }
    try expect(FixtureLog.shared.count("sessionInstall") == 0 && FixtureLog.shared.count("portal:stale-identity") == 0, "existing identity guards retained")
    context.invalidate()
    rows.append("queued-identity-change-rejected-before-install-and-dispatch")
}

func testProviderFailure(_ rows: inout [String]) async throws {
    FixtureLog.shared.reset()
    let context = makeContext("provider-failure", fail: true)
    try await expectFailure({
        try await ILoaderRemoteAuthentication.$current.withValue(context) {
            try await DeveloperPortalProxy.shared.fetchTeams(for: ALTAccount(appleID: "fixture@example.invalid"))
        }
    }, "failed remote provider returned a portal result", matching: { ($0 as? ILoaderRemoteError)?.reasonCode == "invalidResponse" })
    try expect(FixtureLog.shared.count("localFetch") == 0 && FixtureLog.shared.count("sessionInstall") == 0, "provider failure cannot fall back or commit")
    context.invalidate()
    rows.append("remote-provider-failure-never-selects-local-fallback")
}

func testAttemptEndAndCancel(_ rows: inout [String]) async throws {
    FixtureLog.shared.reset()
    let previous = makeContext("ended")
    let operation = SignInOperation(context: previous)
    operation.cancel()
    try await expectFailure({ try await operation.fixturePhaseWrappers() }, "cancelled operation switched routes", matching: { ($0 as? ILoaderRemoteError)?.reasonCode == "consentRequired" })
    try expect(FixtureLog.shared.count("localFetch") == 0, "cancel retains selected sentinel")
    let next = try await SignInOperation(context: nil).execute(parentProgress: nil)
    try expect(next.team.route == "local", "new independent no-selection attempt is default")
    try expect(FixtureLog.shared.count("portal:local") == 2 && FixtureLog.shared.count("portal:ended") == 0, "no background permission leaks")
    try expect(FixtureLog.shared.count("invalidate:ended") == 1, "idempotent revocation")
    rows.append("cancelled-attempt-sentinel-and-next-independent-default")
}

struct Export: Encodable {
    let schema = "iloader-onboarding-scope-cases-v1"
    let fake_only = true
    let cases: [String]
}
@main struct ILoaderOnboardingScopeFixture {
    static func main() async throws {
        // A broken coalescer partition must fail deterministically, not hang CI.
        Task.detached {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            fputs("ILOADER_ONBOARDING_SCOPE_FIXTURE_TIMEOUT\n", stderr)
            exit(2)
        }
        var rows: [String] = []
        try await testOnboarding(&rows)
        try await testConcurrentRoutes(&rows)
        try await testNilClearsAmbient(&rows)
        try await testRevokedDuringVersion(&rows)
        try await testCancelledWaiter(&rows)
        try await testIdentityGuard(&rows)
        try await testProviderFailure(&rows)
        try await testAttemptEndAndCancel(&rows)
        try expect(rows.count == 8 && Set(rows).count == rows.count, "exact unique executed case count")
        if CommandLine.arguments.count > 1 {
            try JSONEncoder().encode(Export(cases: rows)).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("ILOADER_ONBOARDING_SCOPE_FIXTURE_PASS")
        print("{\"case_count\":\(rows.count)}")
    }
}
