#!/usr/bin/env python3
"""Extract real policy/scanner/producer/mapper/classifier; OS/network IO is inert.

The fixture deliberately keeps the complete production scanner control flow.
Only OS interface/address/route storage is replaced with deterministic doubles.
No pairing, device, Apple, authentication, native gateway or network call occurs.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent
INPUTS = {
    'policy': 'SideStore/Dependencies/minimuxer/Sources/RefreshTransportPolicy.swift',
    'producer': 'SideStore/Dependencies/minimuxer/Sources/MinimuxerImpl.swift',
    'scanner': 'SideStore/Dependencies/minimuxer/Sources/Services/NetworkIfaceScanner.swift',
    'observer': 'SideStore/Dependencies/minimuxer/Sources/Services/NetworkObserverService.swift',
    'connection_manager': 'SideStore/Dependencies/minimuxer/Sources/Services/DeviceConnectionManager.swift',
    'minimuxer_error': 'SideStore/Dependencies/minimuxer/Sources/MinimuxerError.swift',
    'api': 'SideStore/Dependencies/minimuxer/Sources/MinimuxerApi.swift',
    'pairing': 'SideStore/Dependencies/minimuxer/Common/PairingProtocol.swift',
    'gateway_error': 'SideStore/Dependencies/minimuxer/DeviceGateway/DeviceGatewayError.swift',
    'mapper': 'SideStore/SideStore/Core/DeviceApi/MinimuxerWrapper.swift',
    'operation_error': 'SideStore/SideStore/Core/Operations/Errors/OperationError.swift',
    'classifier': 'SideStore/SideStore/Core/Operations/PipelineExecutor.swift',
    'selection': 'SideStore/SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift',
}


def declaration(text, anchor):
    start = text.index(anchor)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def no_imports(text):
    return re.sub(r'^(?:public |internal )?import .+\n', '', text, flags=re.M)


def producer_branch(text):
    ready = declaration(text, '    private func readinessObservation(withNetworkCheck:')
    return declaration(ready, '        if decision.transport == .unavailable {')


def wifi_readiness_branch(text):
    ready = declaration(text, '    private func readinessObservation(withNetworkCheck:')
    start = ready.index('        let readinessConfiguration = await network.connectionManager.configurationIdentity()')
    end = ready.index('        // check connection mode', start)
    return ready[start:end]


def wifi_readiness_fixture(producer, observer, manager):
    # Snapshot predicate and readiness decisions are byte-exact production.
    # Only OS observation storage and connection-mode IO are inert boundaries.
    snapshot = declaration(observer, '    struct Snapshot {')
    branch = wifi_readiness_branch(producer)
    unavailable = producer_branch(producer)
    identity = declaration(manager, '    struct ConfigurationIdentity:')
    recheck = declaration(declaration(producer, '    private func readinessObservation(withNetworkCheck:'), '        if let failure = await localObservationFailure()')
    return ('enum DeviceConnectionManager {\n' + identity + '\n}\n' + 'enum LocalVPNWiFiObservation {\n' + snapshot + '\n}\n' + r"""
struct FixtureWiFiManager {
    let mode: DeviceConnectionMode
    func configurationIdentity() async -> DeviceConnectionManager.ConfigurationIdentity {
        .init(generation: 1, mode: mode, overridePeer: "", remotePeer: "")
    }
}
struct FixtureWiFiNetwork {
    let mode: DeviceConnectionMode
    var connectionManager: FixtureWiFiManager { .init(mode: mode) }
    let localVPNWiFiSnapshot: LocalVPNWiFiObservation.Snapshot
    let isWifiSatisfied: Bool
    func logReadinessWiFiObservation(_ snapshot: LocalVPNWiFiObservation.Snapshot) {}
}
struct FixtureWiFiReadiness {
    let network: FixtureWiFiNetwork
    let mode: DeviceConnectionMode
    func getConnectionMode() async -> DeviceConnectionMode { mode }
    func observe(decision: RefreshTransportDecision, withNetworkCheck: Bool = true,
                 owned: Bool = true, transientAllowed: Bool = true) async -> MinimuxerOwnedReadinessObservation {
""" + branch + recheck + "\n" + unavailable + r"""
        // This boundary means the extracted network/interface guards passed,
        // not that native device initialization or any mutation was executed.
        return .init(result: .success(true))
    }
}
""")

def transport_snapshot(text):
    configure = declaration(text, '    private func configureRefreshTransport()')
    start = configure.index('        let interfaces = NetworkIfaceScanner.scan') if '        let interfaces = NetworkIfaceScanner.scan' in configure else configure.index('        let utun = network.isUTunAvailable')
    return configure[start:configure.index('        gateway.configureCoreDeviceTransport', start)]


def readiness_helper(snapshot, branch, suffix=''):
    # Arguments represent a single immutable selection input. The runtime never
    # re-reads an interface or mode after producer error classification.
    snapshot = re.sub(r'\bRefreshTransportPolicy\b', 'RefreshTransportPolicy' + suffix, snapshot)
    if not suffix:
        # Preserve the current producer branch verbatim; only adapt its typed
        # observation return envelope to the historical Result test boundary.
        branch = ('    func observe() -> MinimuxerOwnedReadinessObservation {\n'
                  '        let transientAllowed = false\n' + branch +
                  '\n        return .init(result: .success(true))\n    }\n'
                  '    return observe().result')
    else:
        branch += '\n    return .success(true)'
    return '''
func fixtureTransportDecision%(suffix)s(modernOS: Bool = true,
    mode: DeviceConnectionMode = .localVPN, pairing inputPairing: PairingProtocol = .lockdown,
    coreDeviceSupported: Bool = true) -> RefreshTransportDecision%(suffix)s {
    let network = FixtureObserver.self
    let gateway = FixtureGatewaySnapshot(pairingFileType: inputPairing, supportsCoreDeviceTransport: coreDeviceSupported)
%(snapshot)s
    return decision
}
func fixtureReadinessResult%(suffix)s(decision: RefreshTransportDecision%(suffix)s) -> Result<Bool, MinimuxerError> {
%(branch)s
}
func fixtureReadiness%(suffix)s(modernOS: Bool = true,
    mode: DeviceConnectionMode = .localVPN, pairing: PairingProtocol = .lockdown,
    coreDeviceSupported: Bool = true) -> OperationError? {
    let decision = fixtureTransportDecision%(suffix)s(modernOS: modernOS, mode: mode,
        pairing: pairing, coreDeviceSupported: coreDeviceSupported)
    if case .failure(let error) = fixtureReadinessResult%(suffix)s(decision: decision) {
        return error.asOperationError
    }
    return nil
}
''' % dict(suffix=suffix, snapshot=snapshot, branch=branch)


def generate_source(root, include_operation_classifier=True, include_baseline=True):
    root = Path(root).resolve()
    paths = {name: root / relative for name, relative in INPUTS.items()}
    s = {name: path.read_text() for name, path in paths.items()}
    swift = 'import Foundation\n'
    swift += (HERE / 'interface_doubles.swift').read_text() + '\n'
    if include_operation_classifier:
        swift += 'func debugLog(_ text: String) {}\nfunc verboseLog(_ text: String) {}\n'
    swift += declaration(s['api'], 'public enum DeviceConnectionMode:') + '\n'
    swift += declaration(s['api'], 'public enum MinimuxerOwnedReadinessTransient:') + '\n'
    swift += declaration(s['api'], 'public struct MinimuxerOwnedReadinessObservation') + '\n'
    swift += 'enum MinimuxerConstants { static let remotePairingPort: UInt16 = 58783; static let lockdowndPort: UInt16 = 62078 }\n'
    swift += declaration(s['pairing'], 'public enum PairingProtocol:') + '\n'
    swift += declaration(s['gateway_error'], 'open class DeviceGatewayError:') + '\n'
    swift += declaration(s['minimuxer_error'], 'public enum MinimuxerError:') + '\n'
    swift += declaration(s['minimuxer_error'], 'extension DeviceGatewayError {') + '\n'
    swift += declaration(s['mapper'], 'extension MinimuxerError {') + '\n'
    swift += declaration(s['scanner'], 'internal enum NetworkIfaceScanner {') + '\n'
    swift += 'enum FixtureObserver {\n'
    for anchor in ['    var isUTunAvailable:', '    var isIKEv2IPSecAvailable:']:
        swift += declaration(s['observer'], anchor).replace('    var ', '    static var ', 1) + '\n'
    swift += '}\n' + no_imports(s['policy']) + '\n'
    swift += 'struct FixtureGatewaySnapshot { let pairingFileType: PairingProtocol; let supportsCoreDeviceTransport: Bool }\n'
    swift += readiness_helper(transport_snapshot(s['producer']), producer_branch(s['producer']))
    swift += wifi_readiness_fixture(s['producer'], s['observer'], s['connection_manager'])
    if include_operation_classifier:
        swift += no_imports(s['operation_error']) + '\n'
        swift += declaration(s['selection'], 'struct V3RefreshSelectionFailure:') + '\n'
        swift += declaration(s['classifier'], 'func lcRefreshFailureFacts(') + '\n'
    if include_baseline:
        receipt = json.loads((HERE / 'baseline-receipt.json').read_text())
        baseline = {}
        for name in ['OriginalRefreshTransportPolicy.swift', 'OriginalReadinessUnavailable.swift', 'OriginalTransportSnapshot.swift']:
            raw = (HERE / name).read_bytes()
            if hashlib.sha256(raw).hexdigest() != receipt['extracts'][name]['sha256']:
                raise ValueError('Frozen baseline extraction changed: ' + name)
            baseline[name] = raw.decode()
        policy = no_imports(baseline['OriginalRefreshTransportPolicy.swift'])
        # Rename exact original declarations, not their decisions/guards.
        for original in ['RefreshTransportDecision', 'RefreshTransportPolicy', 'RefreshTransport']:
            policy = re.sub(r'\b' + original + r'\b', original + 'BeforeRepair', policy)
        swift += policy + '\n'
        swift += readiness_helper(baseline['OriginalTransportSnapshot.swift'], baseline['OriginalReadinessUnavailable.swift'], 'BeforeRepair')
    paths.update({name: HERE / name for name in [
        'generate_fixture.py', 'interface_doubles.swift', 'OriginalRefreshTransportPolicy.swift',
        'OriginalReadinessUnavailable.swift', 'OriginalTransportSnapshot.swift', 'baseline-receipt.json']})
    return swift, paths


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--no-main', action='store_true')
    args = parser.parse_args()
    swift, paths = generate_source(args.root)
    if not args.no_main:
        swift += (HERE / 'policy_cases.swift').read_text()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(swift)
    receipt = {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
               for name, path in paths.items()}
    args.output.with_suffix('.inputs.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('VPN_TRANSPORT_FIXTURE_GENERATED ' + str(args.output))

if __name__ == '__main__':
    main()
