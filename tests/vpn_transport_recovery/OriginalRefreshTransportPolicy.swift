import Foundation
public import MinimuxerCommon

public enum RefreshTransport: String, Sendable {
    case coreDevice = "COREDEVICE_LOCALDEVVPN"
    case lockdownIPSec = "LOCKDOWN_IPSEC"
    case lockdownLegacy = "LOCKDOWN_LEGACY"
    case remotePairing = "REMOTE_PAIRING"
    case proxy = "UPSTREAM_PROXY"
    case unavailable = "FAILED_NO_VALID_TRANSPORT"
}

public struct RefreshTransportDecision: Sendable {
    public let transport: RefreshTransport
    public let reason: String
}

public enum RefreshTransportPolicy {
    public static func select(modernOS: Bool, mode: DeviceConnectionMode,
                              pairing: PairingProtocol, utun: Bool, ipsec: Bool,
                              coreDeviceSupported: Bool) -> RefreshTransportDecision {
        if pairing == .unknown {
            return .init(transport: .unavailable, reason: "No valid pairing record")
        }
        if mode == .remoteServer {
            return .init(transport: .proxy, reason: "Explicit upstream remote-server configuration")
        }
        guard mode == .localVPN, utun else {
            return .init(transport: .unavailable, reason: "Local VPN requires a reachable utun route; IPSec alone is not an upstream local-VPN route")
        }
        if pairing == .rppairing {
            return .init(transport: .remotePairing, reason: "RemotePairing-only record; not CoreDevice proof")
        }
        if modernOS && coreDeviceSupported {
            return .init(transport: .coreDevice, reason: "iOS>=26.4 local VPN with Lockdown record and patched CoreDevice backend; initialization pending")
        }
        if ipsec {
            return .init(transport: .lockdownIPSec, reason: "Upstream Lockdown with utun and IPSec interfaces")
        }
        if !modernOS {
            return .init(transport: .lockdownLegacy, reason: "Preserve upstream Lockdown below iOS26.4")
        }
        return .init(transport: .unavailable, reason: "Selected backend has no CoreDevice implementation and IPSec is absent")
    }
}
