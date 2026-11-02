final class FixtureGroup: @unchecked Sendable {
    let progress = Progress(totalUnitCount: 100)
    func setVerification(_ verification: V3RefreshVerification, for identifier: String) {}
}
final class FixtureProgress: @unchecked Sendable {
    let value = Progress(totalUnitCount: 100)
    private let lock = NSLock()
    private var present = true
    func removeCancelledEntry() { lock.withLock { present = false } }
    func progress(for operation: String) -> Progress? { lock.withLock { present ? value : nil } }
    func progress(for operation: AppOperation) -> Progress? { progress(for: operation.bundleIdentifier) }
}
final class FixtureAdmission { func check() throws {} }

// Test-only observation; the scheduler/lease above is extracted verbatim.
extension V3ProfileTransactionLane {
    func fixtureQueueCount() -> Int { lock.withLock { queue.count } }
}

final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var inventory = 0
    private var live = 0
    private var calls = 0
    private var admitted = true
    func begin() -> Int {
        lock.withLock {
            live += 1
            precondition(live == 1, "Transactions interleaved across an await")
            calls += 1
            return inventory
        }
    }
    func commit(_ snapshot: Int) {
        lock.withLock {
            precondition(inventory == snapshot, "Snapshot invalidated by another operation")
            inventory += 1
        }
    }
    func finish(_ snapshot: Int) {
        lock.withLock { precondition(inventory == snapshot + 1); live -= 1 }
    }
    func revoke() { lock.withLock { admitted = false } }
    func check() throws { if !lock.withLock({ admitted }) { throw FixtureError.revoked } }
    func count() -> Int { lock.withLock { calls } }
}
final class FixtureOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) { lock.withLock { values.append(value) } }
    func read() -> [Int] { lock.withLock { values } }
}
enum FixtureError: Error { case revoked, injected }

func waitForQueue(_ lane: V3ProfileTransactionLane, _ count: Int) async {
    // Scheduling-only yields; no timeout-dependent sleeps or device interaction.
    while lane.fixtureQueueCount() != count { await Task.yield() }
}

@main struct SerializationCases {
    static func main() async throws {
        let lane = V3ProfileTransactionLane.shared
        let state = FixtureState()
        // Simultaneous direct calls, distinct runner batches and operation kinds
        // all share the production process-wide lane. Native awaits are inert.
        await withTaskGroup(of: Void.self) { tasks in
            for _ in 0..<48 {
                tasks.addTask {
                    let ticket = try! await lane.acquire()
                    defer { lane.release(ticket) }
                    let snapshot = state.begin()
                    for _ in 0..<4 { await Task.yield() }
                    state.commit(snapshot)
                    for _ in 0..<4 { await Task.yield() }
                    state.finish(snapshot) // post-readback + result accounting
                }
            }
        }
        precondition(state.count() == 48)
        print("PASS separate_batches_direct_calls_and_mixed_mutations")

        let fifoOwner = try await lane.acquire()
        let order = FixtureOrder()
        var fifoTasks: [Task<Void, Error>] = []
        for index in 0..<8 {
            fifoTasks.append(Task {
                let ticket = try await lane.acquire()
                defer { lane.release(ticket) }
                order.append(index)
                await Task.yield()
            })
            await waitForQueue(lane, index + 1)
        }
        lane.release(fifoOwner)
        for task in fifoTasks { try await task.value }
        precondition(order.read() == Array(0..<8))
        print("PASS_fifo_queued_transactions")

        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let ticket = try await lane.acquire()
            defer { lane.release(ticket) }
            preconditionFailure("Pre-cancelled operation acquired")
        }
        do { _ = try await alreadyCancelled.value; preconditionFailure() }
        catch is CancellationError {} catch { throw error }
        print("PASS_cancellation_before_continuation_registration")

        for cancelGroup in [true, false] {
            let group = FixtureGroup()
            let progress = FixtureProgress()
            // This closure is extracted verbatim from performOperation, not a
            // fixture reimplementation of the production cancellation guard.
            let check = makeAdmission(group: group, progress: progress, operation: "app")
            try check()
            let ticket = try await lane.acquire()
            do {
                defer { lane.release(ticket) }
                try check()
                await Task.yield() // e.g. portal/profile read awaiting completion
                if cancelGroup { group.progress.cancel() } else { progress.value.cancel() }
                do { try check(); preconditionFailure("Cancelled progress reached mutation") }
                catch is CancellationError {} catch { throw error }
            }
        }
        print("PASS_extracted_admission_progress_cancel_after_grant_before_mutation")

        let composedRunner = FixtureRunner()
        let composedGroup = RefreshGroup()
        let composed = Task {
            try await composedRunner.performOperation(for: AppOperation(bundleIdentifier: "com.fixture.app"),
                handler: PipelineExecutionHandler(), group: composedGroup)
        }
        await composedRunner.entered.wait()
        composedRunner.progress.value.cancel()
        composedRunner.progress.removeCancelledEntry()
        precondition(composedRunner.progress.progress(for: "com.fixture.app") == nil)
        await composedRunner.resume.release()
        do { try await composed.value; preconditionFailure("Removed cancelled progress reached mutation") }
        catch is CancellationError {} catch { throw error }
        precondition(composedRunner.mutations.count() == 0)
        let afterComposedCancellation = try await lane.acquire()
        lane.release(afterComposedCancellation)
        print("PASS_composed_production_entry_retains_cancelled_progress_after_removal")

        let held = try await lane.acquire()
        let cancelled = Task {
            let ticket = try await lane.acquire()
            defer { lane.release(ticket) }
            preconditionFailure("Queued cancelled operation executed")
        }
        await waitForQueue(lane, 1)
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure() }
        catch is CancellationError {} catch { throw error }
        precondition(lane.fixtureQueueCount() == 0)
        lane.release(held)
        print("PASS queued_cancellation_without_owner_release")

        let revoked = FixtureState()
        let blocker = try await lane.acquire()
        let waiting = Task {
            try revoked.check() // same before/after grant admission contract
            let ticket = try await lane.acquire()
            defer { lane.release(ticket) }
            try revoked.check()
            _ = revoked.begin()
        }
        await waitForQueue(lane, 1)
        revoked.revoke()
        lane.release(blocker)
        do { try await waiting.value; preconditionFailure() }
        catch FixtureError.revoked {} catch { throw error }
        precondition(revoked.count() == 0)
        print("PASS expired_admission_cannot_start_snapshot")

        // Exercise both grant/cancel orders repeatedly. Whichever wins, the next
        // independent transaction must acquire, with no leaked/double ownership.
        for index in 0..<200 {
            let owner = try await lane.acquire()
            let next = Task {
                let ticket = try await lane.acquire()
                defer { lane.release(ticket) }
                try Task.checkCancellation()
            }
            await waitForQueue(lane, 1)
            if index.isMultiple(of: 2) { next.cancel(); lane.release(owner) }
            else { lane.release(owner); next.cancel() }
            do { try await next.value } catch is CancellationError {} catch { throw error }
            let probe = try await lane.acquire()
            lane.release(owner) // stale owner must not release probe
            lane.release(probe)
        }
        print("PASS cancellation_grant_races_and_stale_release")

        do {
            let ticket = try await lane.acquire()
            defer { lane.release(ticket) }
            throw FixtureError.injected
        } catch FixtureError.injected {}
        let afterFailure = try await lane.acquire()
        lane.release(afterFailure)
        print("PASS_error_release_no_replay")
        print("PASS native_production_lane_cases_complete")
    }
}
