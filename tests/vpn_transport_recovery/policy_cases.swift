@main struct VPNTransportRecoveryTests {
    static func require(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
    }
    static func facts(_ error: OperationError?) -> [String: String] {
        guard let error else { return [:] }
        return lcRefreshFailureFacts(error, sourceStep: "refreshReadiness")
    }
    static func main() {
        // Full transport result parity, plus finite negative classification.
        var cases = 0
        for modern in [false, true] {
            for mode in [DeviceConnectionMode.notConfigured, .localVPN, .remoteServer] {
                for pairing in [PairingProtocol.unknown, .lockdown, .rppairing] {
                    for utun in [false, true] {
                        for ipsec in [false, true] {
                            for supported in [false, true] {
                                let current = RefreshTransportPolicy.select(modernOS: modern, mode: mode, pairing: pairing,
                                    utun: utun, ipsec: ipsec, coreDeviceSupported: supported)
                                let before = RefreshTransportPolicyBeforeRepair.select(modernOS: modern, mode: mode, pairing: pairing,
                                    utun: utun, ipsec: ipsec, coreDeviceSupported: supported)
                                require(current.transport.rawValue == before.transport.rawValue, "Transport matrix changed")
                                require(current.reason == before.reason, "Existing diagnostic message changed")
                                let eligible = pairing != .unknown && mode == .localVPN && !utun &&
                                    (!modern || pairing == .rppairing || supported || ipsec)
                                if case .failure(let error) = fixtureReadinessResult(decision: current) {
                                    let observed = facts(error.asOperationError)
                                    require((observed["refresh_readiness_reason"] == "vpnUnavailable") == eligible,
                                        "Readiness recovery escaped exact local-VPN/interface snapshot")
                                    require(observed["refresh_failure_kind"] == (eligible ? "noVPN" : "invalidVPN"),
                                        "Existing non-interface error family changed")
                                } else { require(!eligible, "Missing interface unexpectedly selected transport") }
                                cases += 1
                            }
                        }
                    }
                }
            }
        }
        require(cases == 144, "Incomplete transport matrix")
        // Execute the ACTUAL scanner, observer, policy, producer, mapper and
        // classifier against one synthetic OS snapshot, including index guard.
        let snapshots: [[FixtureOS.Interface]] = [
            [.init(name: "utun0", up: true, address: nil)], [],
            [.init(name: "utun0", up: false, address: "10.7.0.1")],
            [.init(name: "utun0", up: true, address: "10.7.0.1", index: 0)]]
        for snapshot in snapshots {
            FixtureOS.setInterfaces(snapshot)
            require(!FixtureObserver.isUTunAvailable, "Unusable utun accepted by actual scanner")
            let old = facts(fixtureReadinessBeforeRepair())
            let new = facts(fixtureReadiness())
            require(old["refresh_failure_kind"] == "invalidVPN" && old["refresh_readiness_reason"] == nil,
                "Exact delivered baseline no longer reproduces missing recovery reason")
            require(new == ["refresh_failure_kind": "noVPN", "refresh_readiness_reason": "vpnUnavailable"],
                "Eligible scanner rejection did not gain finite recovery reason")
            require(facts(fixtureReadiness(mode: .notConfigured))["refresh_readiness_reason"] == nil,
                "Unconfigured mode triggered VPN activation")
            require(facts(fixtureReadiness(pairing: .unknown))["refresh_readiness_reason"] == nil,
                "Missing pairing triggered VPN activation")
            require(facts(fixtureReadiness(coreDeviceSupported: false))["refresh_readiness_reason"] == nil,
                "Unsupported modern backend triggered VPN activation")
            require(fixtureReadiness(mode: .remoteServer) == nil, "Remote-server path changed")
        }
        for address in ["10.7.0.1", "fd00::1"] {
            FixtureOS.setInterfaces([.init(name: "utun0", address: address)])
            require(FixtureObserver.isUTunAvailable, "Usable IPv4/IPv6 utun rejected")
            require(fixtureReadiness() == nil, "Usable interface incorrectly failed policy")
            require(facts(fixtureReadiness(coreDeviceSupported: false))["refresh_readiness_reason"] == nil,
                "Unsupported backend with usable interface triggered activation")
        }
        // A post-decision environment change must not rewrite the prior cause.
        FixtureOS.setInterfaces([])
        let captured = fixtureTransportDecision()
        FixtureOS.setInterfaces([.init(name: "utun0", address: "10.7.0.1")])
        if case .failure(let error) = fixtureReadinessResult(decision: captured) {
            require(facts(error.asOperationError)["refresh_readiness_reason"] == "vpnUnavailable", "Decision cause was resampled")
        } else { preconditionFailure("Captured missing-interface decision unexpectedly succeeded") }
        // Preserve all gateway/OperationError families and explicitly reject
        // arbitrary provider strings, pairing errors, and the old shared reason.
        let excluded: [MinimuxerError] = [
            .invalidPairing(protocol: .lockdown, reason: "synthetic-private-pairing"),
            .pairingNotLoaded("synthetic-private-pairing"), .connectionModeNotConfigured("synthetic-mode"),
            .createCoreDevice("synthetic-backend"), .createLockdown("synthetic-lockdown"),
            .getLockdownValue("synthetic-value"), .connect("synthetic-heartbeat"), .noService("synthetic-service"),
            .noDevice("synthetic-native-endpoint"), .invalidVPN("synthetic-provider-failure"),
            .invalidVPN("Local VPN requires a reachable utun route; IPSec alone is not an upstream local-VPN route")]
        for error in excluded {
            require(facts(error.asOperationError)["refresh_readiness_reason"] == nil, "Non-interface failure gained recovery")
        }
        for message in ["broken pipe", "connection reset", "no route to host", "connection refused"] {
            let provider = DeviceGatewayError(.connectionFailed, reason: message)
            let native = provider.asMinimuxerError(protocol: .lockdown, catchAll: MinimuxerError.fetchUDID)
            require(facts(native.asOperationError)["refresh_failure_kind"] == "invalidVPN", "Native VPN-drop family changed")
            require(facts(native.asOperationError)["refresh_readiness_reason"] == nil, "Unproven native VPN drop became activation-eligible")
        }
        let pairing = DeviceGatewayError(.invalidPairingFile, reason: "connection reset")
            .asMinimuxerError(protocol: .lockdown, catchAll: MinimuxerError.fetchUDID)
        require(facts(pairing.asOperationError)["refresh_failure_kind"] == "invalidPairingFile", "Pairing precedence lost")
        require(facts(pairing.asOperationError)["refresh_readiness_reason"] == nil, "Pairing gained recovery")
        let unrelatedStep = lcRefreshFailureFacts(OperationError.noVPN(reason: "synthetic"), sourceStep: "refreshApplication")
        require(unrelatedStep["refresh_readiness_reason"] == nil, "Recovery escaped readiness boundary")
        FixtureOS.reset()
        print("VPN_TRANSPORT_RECOVERY_PASS transport_cases=144 actual_scanner=pass baseline_failure_reproduced=pass finite_exclusions=pass")
    }
}
