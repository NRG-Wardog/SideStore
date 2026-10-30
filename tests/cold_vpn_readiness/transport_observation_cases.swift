enum OperationError: Error { case minimuxerNotStarted(reason: String), cancelled }
enum PairingProtocol { case rppairing }
final class Gateway { var port: UInt16 = 1; var coreDeviceTransportEnabled = true; func getPort(for mode: PairingProtocol) -> UInt16 { port } }
final class NativeCore {
    var result: Result<Bool, OperationError> = .success(true)
    var during: () -> Void = {}
    func isReady(withNetworkCheck: Bool, withDDIMountCheck: Bool) async -> Result<Bool, OperationError> { during(); return result }
}
final class Facade { var core = NativeCore(); var gateway = Gateway() }
let minimuxer = Facade()
final class ConnectionConfig {
    static let shared = ConnectionConfig()
    var useLocalVPN = true; var overrideTunnelPeerIp = ""; var remoteServerIp = "fixture"
}
final class V3PairingTransportReceipt {
    static let shared = V3PairingTransportReceipt(); var generation = UUID()
    func observationGeneration() -> UUID { generation }
}
final class CellularRefreshManager { static let shared = CellularRefreshManager(); var isEnabled = false }
final class Group {
    var observation = V3OwnedTransportObservation()
    func recordTransportReady(nativeReady: Bool, configurationUnchanged: Bool,
                              checkOwnership: () throws -> Void) rethrows {
        try observation.recordReady(nativeReady: nativeReady, configurationUnchanged: configurationUnchanged,
                                    checkOwnership: checkOwnership)
    }
}
func extractedNative(_ group: Group, checkReadinessOwnership: () throws -> Void) async throws {
    let transportCore = minimuxer.core
    let transportObservationConfiguration = V3TransportObservationConfiguration.capture()
    // EXACT_NATIVE_BRANCH
}
func extractedRemote(_ group: Group, checkReadinessOwnership: () throws -> Void) async throws {
    let transportCore = minimuxer.core
    let transportObservationConfiguration = V3TransportObservationConfiguration.capture()
    // EXACT_REMOTE_BRANCH
}
@main struct Main {
    static func main() async throws {
        let run = UUID().uuidString; let next = UUID().uuidString
        func group() -> Group { let g=Group(); g.observation.bind(to:run); return g }
        let successful=group(); try await extractedNative(successful,checkReadinessOwnership:{})
        let wire=successful.observation.wire(for:run)!
        precondition(Set(wire.keys)==["version","readiness","scope"])
        precondition(wire["version"] as? Int == 1 && wire["readiness"] as? String == "ready" && wire["scope"] as? String == "ownedBatch")
        successful.observation.bind(to:next); precondition(successful.observation.wire(for:next)==nil)
        // Later install failure does not erase the earlier historical observation.
        let laterFailure: Result<Void,OperationError> = .failure(.cancelled)
        if case .failure = laterFailure { precondition(successful.observation.wire(for:run) != nil) }
        let rejected: [Result<Bool,OperationError>] = [.success(false), .failure(.cancelled)]
        for result in rejected {
            minimuxer.core.result=result; let g=group()
            do { try await extractedNative(g,checkReadinessOwnership:{}); preconditionFailure("native false/failure accepted") } catch {}
            precondition(g.observation.wire(for:run)==nil)
        }
        minimuxer.core.result = .success(true)
        minimuxer.core.result = .success(false)
        let remoteFalse=group(); try await extractedRemote(remoteFalse,checkReadinessOwnership:{})
        precondition(remoteFalse.observation.wire(for:run)==nil) // Original false-return behavior retained.
        minimuxer.core.result = .failure(.cancelled);let remoteFailure=group()
        do { try await extractedRemote(remoteFailure,checkReadinessOwnership:{}); preconditionFailure("remote failure accepted") } catch {}
        precondition(remoteFailure.observation.wire(for:run)==nil)
        minimuxer.core.result = .success(true);let remoteReady=group()
        try await extractedRemote(remoteReady,checkReadinessOwnership:{})
        precondition(remoteReady.observation.wire(for:run) != nil)
        var cancelled=false; minimuxer.core.during={cancelled=true};let late=group()
        do { try await extractedNative(late,checkReadinessOwnership:{ if cancelled { throw OperationError.cancelled } }); preconditionFailure("late cancel accepted") } catch {}
        precondition(late.observation.wire(for:run)==nil)
        cancelled=false;let remoteLate=group()
        do { try await extractedRemote(remoteLate,checkReadinessOwnership:{ if cancelled { throw OperationError.cancelled } }); preconditionFailure("remote late cancel accepted") } catch {}
        precondition(remoteLate.observation.wire(for:run)==nil)
        let changes:[()->Void] = [
            { ConnectionConfig.shared.useLocalVPN.toggle() },
            { ConnectionConfig.shared.overrideTunnelPeerIp += "x" },
            { ConnectionConfig.shared.remoteServerIp += "x" },
            { minimuxer.gateway.port += 1 },
            { minimuxer.gateway.coreDeviceTransportEnabled.toggle() },
            { minimuxer.gateway = Gateway() },
            { V3PairingTransportReceipt.shared.generation = UUID() },
            { CellularRefreshManager.shared.isEnabled.toggle() },
            { minimuxer.core = NativeCore() }
        ]
        for change in changes {
            minimuxer.core.during=change;let g=group();try await extractedNative(g,checkReadinessOwnership:{})
            precondition(g.observation.wire(for:run)==nil)
        }
        minimuxer.core.during={};let unbound=Group();try await extractedNative(unbound,checkReadinessOwnership:{})
        precondition(unbound.observation.wire(for:run)==nil)
        var invalid=V3OwnedTransportObservation();invalid.bind(to:"invalid")
        invalid.recordReady(nativeReady:true,configurationUnchanged:true,checkOwnership:{})
        precondition(invalid.wire(for:"invalid")==nil)
        print("OWNED_TRANSPORT_OBSERVATION_PASS native_true=1 native_false_failure=2 remote_true_false_failure=3 late_cancel=2 changed_configuration=9 unbound=1 invalid_run=1 stale_run=1 later_failure_preserved=1")
    }
}
