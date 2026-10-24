// V3_HEADLESS_BACKEND_CONNECTION_CONFIG_V1: backend-owned transport configuration.
import Foundation
import Minimuxer

final class ConnectionConfig {
    static let shared = ConnectionConfig()

    private static var defaultOverrideIP: String { "" }
    private static var defaultRemoteServerIP: String { AppConstants.Connection.defaultRemoteServerIP }
    private static var defaultWireGuardServerHost: String { AppConstants.Proxy.address }
    private static var defaultWireGuardServerPort: UInt16 { AppConstants.Proxy.defaultPort }

    var tunnelIfaceIp: String?
    var tunnelIfaceSubnetMask: String?
    var tunnelPeerIp: String?
    var tunnelPeerSubnetMask: String?
    var tunnelPeerReachable = false
    var overrideTunnelPeerReachable = false
    var remotePeerIp: String?
    var remoteReachable = false

    // Read persisted settings on every access. LiveContainer writes these keys
    // directly through settingsSet, so a cached value would leave the already-
    // bound Minimuxer connection-mode callback stale for the process lifetime.
    var overrideTunnelPeerIp: String {
        get { UserDefaults.standard.tunnelOverridePeerIp ?? Self.defaultOverrideIP }
        set { UserDefaults.standard.tunnelOverridePeerIp = newValue }
    }

    var remoteServerIp: String {
        get { UserDefaults.standard.remoteServerIp ?? Self.defaultRemoteServerIP }
        set { UserDefaults.standard.remoteServerIp = newValue }
    }

    var useLocalVPN: Bool {
        get { UserDefaults.standard.useLocalVPN }
        set { UserDefaults.standard.useLocalVPN = newValue }
    }

    var wireguardServerHost: String {
        get { UserDefaults.standard.wireGuardServerHost ?? Self.defaultWireGuardServerHost }
        set { UserDefaults.standard.wireGuardServerHost = newValue }
    }

    var wireguardServerPort: UInt16 {
        get { UserDefaults.standard.wireGuardServerPort ?? Self.defaultWireGuardServerPort }
        set { UserDefaults.standard.wireGuardServerPort = newValue }
    }

    var connectionMode: DeviceConnectionMode {
        useLocalVPN ? .localVPN : .remoteServer
    }
}

extension UserDefaults {
    @objc var tunnelOverridePeerIp: String? {
        get { self.string(forKey: "TunnelOverridePeerIp") }
        set { self.set(newValue, forKey: "TunnelOverridePeerIp") }
    }

    @objc var remoteServerIp: String? {
        get { self.string(forKey: "RemoteServerIp") }
        set { self.set(newValue, forKey: "RemoteServerIp") }
    }

    @objc var wireGuardServerHost: String? {
        get { self.string(forKey: "WireGuardServerHost") }
        set { self.set(newValue, forKey: "WireGuardServerHost") }
    }

    var wireGuardServerPort: UInt16? {
        get {
            guard self.object(forKey: "WireGuardServerPort") != nil else { return nil }
            let val = self._wireGuardServerPort
            return (val > 0 && val <= 65535) ? UInt16(val) : nil
        }
        set {
            if let newValue {
                self._wireGuardServerPort = Int(newValue)
            } else {
                self.removeObject(forKey: "WireGuardServerPort")
            }
        }
    }

    @objc(wireGuardServerPort) private var _wireGuardServerPort: Int {
        get { self.integer(forKey: "WireGuardServerPort") }
        set { self.set(newValue, forKey: "WireGuardServerPort") }
    }
}
