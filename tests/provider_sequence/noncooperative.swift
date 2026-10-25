import Foundation

actor Probe {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending = false
    private var joined = false
    func block() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
    func waitUntilBlocked() async {
        if continuation != nil { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    func waitUntilPending() async {
        if pending { return }
        await withCheckedContinuation { pendingWaiters.append($0) }
    }
    func markPending() {
        pending = true
        let waiters = pendingWaiters
        pendingWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
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
                        // Synthetic deadline fires only once the noncooperative
                        // child is demonstrably suspended, independent of load.
                        await probe.waitUntilBlocked()
                        throw V3DiagnosticAttemptTimeout()
                    }
                    defer { group.cancelAll() }
                    do {
                        _ = try await group.next()
                    } catch {
                        group.cancelAll()
                        // Signal only after the timeout was observed and child
                        // cancellation requested, while group scope still joins.
                        await probe.markPending()
                        throw error
                    }
                }
            } catch { }
            await probe.markJoined()
        }
        await probe.waitUntilPending()
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
