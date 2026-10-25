import Foundation

actor Probe {
    var continuation: CheckedContinuation<Void, Never>?
    var pending = false
    var joined = false
    func block() async { await withCheckedContinuation { continuation = $0 } }
    func markPending() { pending = true }
    func markJoined() { joined = true }
    func snapshot() -> (Bool, Bool) { (pending, joined) }
    func release() { continuation?.resume(); continuation = nil }
}

@main struct NoncooperativeAttemptTest {
    static func main() async throws {
        let probe = Probe()
        var policy = V3DiagnosticProviderSequence(plan: V3DiagnosticProviderPlan(["remoteServer", "remoteMac"])!)
        let attempt = policy.start(now: 0)!
        let work = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { await probe.block() } // Deliberately ignores cancellation.
                    group.addTask {
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await probe.markPending()
                        throw V3DiagnosticAttemptTimeout()
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch { }
            await probe.markJoined()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeDrain = await probe.snapshot()
        precondition(beforeDrain.0 && !beforeDrain.1, "timeout must remain cleanup-pending")
        policy.failed(attempt, reason: .timedOut)
        precondition(policy.continueAfterBackoff(now: 1000) == nil, "no retry before join evidence")
        await probe.release()
        await work.value
        let afterDrain = await probe.snapshot()
        precondition(afterDrain.1, "joined only after cancelled child drained")
        // The configured-server runtime intentionally stops after its timeout,
        // even after draining. Do not supply the policy's retry admission event.
        policy.cancel()
        precondition(policy.continueAfterBackoff(now: 1001) == nil, "no post-timeout rotation")
        print("Noncooperative cancellation: 4 checks passed")
    }
}
