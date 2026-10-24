// Inert OS/address/route storage only. Selection/filtering is extracted production
// NetworkIfaceScanner.scan. Never call Darwin/Glibc interfaces or native devices.
let IFF_UP: Int32 = 1
let IFF_POINTOPOINT: Int32 = 16
let AF_INET: Int32 = 2
let AF_INET6: Int32 = 30
struct sockaddr { var sa_family: UInt8; var fixtureAddress: String }
struct ifaddrs {
    var ifa_next: UnsafeMutablePointer<ifaddrs>?
    var ifa_name: UnsafeMutablePointer<CChar>
    var ifa_flags: UInt32
    var ifa_addr: UnsafeMutablePointer<sockaddr>?
    var ifa_netmask: UnsafeMutablePointer<sockaddr>?
    var ifa_dstaddr: UnsafeMutablePointer<sockaddr>?
}
enum FixtureOS {
    struct Interface {
        var name: String
        var up: Bool
        var address: String?
        var index: UInt32
        init(name: String, up: Bool = true, address: String? = nil, index: UInt32 = 1) {
            self.name = name; self.up = up; self.address = address; self.index = index
        }
    }
    static var interfaces: [Interface] = []
    static var head: UnsafeMutablePointer<ifaddrs>?
    static var entries: [UnsafeMutablePointer<ifaddrs>] = []
    static var names: [UnsafeMutablePointer<CChar>] = []
    static var addresses: [UnsafeMutablePointer<sockaddr>] = []
    static var scans = 0
    static func reset() {
        for entry in entries { entry.deinitialize(count: 1); entry.deallocate() }
        for address in addresses { address.deinitialize(count: 1); address.deallocate() }
        for name in names { name.deallocate() }
        head = nil; entries = []; addresses = []; names = []; interfaces = []; scans = 0
    }
    static func setInterfaces(_ values: [Interface]) {
        reset(); interfaces = values
        for value in values {
            let bytes = Array(value.name.utf8CString)
            let name = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            for (offset, byte) in bytes.enumerated() { name.advanced(by: offset).initialize(to: byte) }
            names.append(name)
            var addr: UnsafeMutablePointer<sockaddr>?
            if let text = value.address {
                let pointer = UnsafeMutablePointer<sockaddr>.allocate(capacity: 1)
                pointer.initialize(to: .init(sa_family: UInt8(text.contains(":") ? AF_INET6 : AF_INET), fixtureAddress: text))
                addresses.append(pointer); addr = pointer
            }
            let entry = UnsafeMutablePointer<ifaddrs>.allocate(capacity: 1)
            entry.initialize(to: .init(ifa_next: nil, ifa_name: name,
                ifa_flags: value.up ? UInt32(IFF_UP) : 0,
                ifa_addr: addr, ifa_netmask: addr, ifa_dstaddr: nil))
            entries.last?.pointee.ifa_next = entry
            entries.append(entry)
        }
        head = entries.first
    }
}
func getifaddrs(_ destination: inout UnsafeMutablePointer<ifaddrs>?) -> Int32 {
    FixtureOS.scans += 1; destination = FixtureOS.head; return 0
}
func freeifaddrs(_ head: UnsafeMutablePointer<ifaddrs>?) {}
func if_nametoindex(_ name: String) -> UInt32 { FixtureOS.interfaces.first { $0.name == name }?.index ?? 0 }
struct IPv4Info {
    let host: String
    let mask: String
    let hostRaw: UInt32
    let maskRaw: UInt32
    init?(ifa: ifaddrs) {
        guard let address = ifa.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { return nil }
        self.init(host: address.pointee.fixtureAddress, mask: "255.255.255.0", hostRaw: 1, maskRaw: 0xFFFFFF00)
    }
    init(host: String, mask: String, hostRaw: UInt32, maskRaw: UInt32) {
        self.host = host; self.mask = mask; self.hostRaw = hostRaw; self.maskRaw = maskRaw
    }
}
struct IPAddresses { var v4: [IPv4Info] = []; var v6: [String] = [] }
struct IP { var v4: IPv4Info?; var v6: String? }
func sockaddrIPv4(_ address: inout sockaddr) -> UInt32? { nil }
func ipv4String(_ value: UInt32) -> String? { nil }
func sockaddrIPv6(_ address: inout sockaddr) -> String? { address.fixtureAddress }
struct RouteSnapshot {
    struct Entry { var interfaceIndex: UInt16 }
    var entries: [Entry] = []
    static func captureRoutes() -> RouteSnapshot { .init() }
}
class NetInfo: Hashable {
    let name: String
    let interfaceIndex: UInt16
    let interfaceAddresses: IPAddresses
    init(name: String, interfaceIndex: UInt16, interfaceAddresses: IPAddresses, routes: RouteSnapshot, flags: Int32) {
        self.name = name; self.interfaceIndex = interfaceIndex; self.interfaceAddresses = interfaceAddresses
    }
    static func ==(lhs: NetInfo, rhs: NetInfo) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}
struct TunnelType { init(interfaceName: String) throws {} }
final class TunnelNetInfo: NetInfo {
    init(name: String, interfaceIndex: UInt16, interfaceAddresses: IPAddresses,
         linkLayerDestinationIP: IP?, routes: RouteSnapshot, flags: Int32) throws {
        super.init(name: name, interfaceIndex: interfaceIndex, interfaceAddresses: interfaceAddresses, routes: routes, flags: flags)
    }
}
func formatNetInfoList(_ list: Set<NetInfo>) -> String { "" }
