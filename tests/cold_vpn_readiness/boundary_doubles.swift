// Inert boundaries for unmodified production admission/probe/injection fragments.
final class V3HeadlessPipelineHandler {
    var duringPhase: () -> Void = {}
    func recordPipelinePhase(_ step: Int, downloadUsesNetwork: Bool) async { duringPhase() }
}
struct PhaseContext { var handler: Any }
struct DownloadingApp { var url: URL? = nil }
enum FakeOperation { case refresh, install }
final class NativeCore {
    var calls = 0
    var duringReadiness: () -> Void = {}
    var result: Result<Bool, MinimuxerError> = .success(true)
    func isReady(withNetworkCheck: Bool, withDDIMountCheck: Bool) async -> Result<Bool, MinimuxerError> {
        calls += 1; duringReadiness(); return result
    }
}
final class CellularRefreshManager {
    static let shared = CellularRefreshManager()
    var duringToggle: () -> Void = {}
    var restored = 0
    func turnOffDataIfNeeded() async { duringToggle() }
    func turnOnDataIfNeeded() async { restored += 1 }
}
struct Profile { var data: Data = Data() }
enum V3RefreshFailureBoundary {
    case provisioningProfileInstallation, refreshRecordUpdate
    func preserving(_ error: Error) -> Error { error }
}
final class InjectionEvidence {
    static let shared = InjectionEvidence()
    var count = 0
    var afterInjection: () -> Void = {}
}
func installProvisioningProfiles(_ data: Data) async throws {
    InjectionEvidence.shared.count += 1
    InjectionEvidence.shared.afterInjection()
}

typealias InstalledApp = Int
final class DatabaseContext {
    func perform(_ body: () throws -> InstalledApp) async throws -> InstalledApp { try body() }
}
struct InjectionContext { let dbBackgroundContext = DatabaseContext() }
final class InjectionHarness {
    let context = InjectionContext()
    var persisted = 0
    func setProgress(_ value: Int) {}
    func updateInstalledApp(for appBundle: Int, profiles: [String: Profile], in context: DatabaseContext) throws -> InstalledApp {
        persisted += 1; return persisted
    }
}
