// Inert platform boundaries for the verbatim common-entry prefix below.
struct AppOperation: Sendable { let bundleIdentifier: String }
struct PipelineExecutionHandler: Sendable {}
typealias RefreshGroup = FixtureGroup
struct V3RefreshVerification {
    let installAcknowledged: Bool
    let mutationDispatched: Bool
}
enum V3RemoteRequestLeases { static let admitted: FixtureAdmission? = nil }
func debugLog(_ message: String) {}
@MainActor final class DatabaseManager {
    static let shared = DatabaseManager()
    let viewContext = FixtureViewContext()
}
@MainActor final class FixtureViewContext { func processPendingChanges() {} }
actor FixtureSignal {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        ready = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
final class FixtureRunner: @unchecked Sendable {
    let progress = FixtureProgress()
    let entered = FixtureSignal()
    let resume = FixtureSignal()
    let mutations = FixtureState()
    func performPipeline(for operation: AppOperation, handler: PipelineExecutionHandler,
                         group: RefreshGroup, operationsCount: Int,
                         refreshAdmission: (() throws -> Void)?,
                         readProfiles: (() async throws -> [Data])?) async throws -> Int {
        // Simulate native/portal read suspension before the existing production
        // pre-dispatch admission point. No profile/device operation is performed.
        await entered.release()
        await resume.wait()
        try refreshAdmission?()
        return mutations.begin()
    }
}
