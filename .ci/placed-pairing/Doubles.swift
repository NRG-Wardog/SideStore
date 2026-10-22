import Foundation

enum PairingProtocol: Equatable { case unknown, lockdown, rppairing }
protocol PairingFile { var mode: PairingProtocol { get } }
struct LockdownPairingFile: PairingFile { let mode = PairingProtocol.lockdown; let udid = "fixture-device" }
enum PairingFileParser {
    static func parse(content: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        FixtureHooks.onParse?()
        guard content.hasPrefix("SYNTHETIC_PAIRING_FIXTURE_ONLY:"), preferred != .rppairing else { throw FixtureFailure.failed }
        return LockdownPairingFile()
    }
}
final class UserDefaults {
    static let standard = UserDefaults()
    var isPairingReset = true
    var activePairingProtocol: PairingProtocol?
    var preferredPairingProtocol: PairingProtocol?
}
enum AppConstants {
    enum Pairing {
        static let lockdownPairingFileName = "PairingFile_Lockdown.plist"
        static let remotePairingFileName = "PairingFile_RemoteRP.plist"
        static let legacyPairingFileName = "ALTPairingFile.mobiledevicepairing"
    }
}
enum FixtureStore {
    static var root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    static var logs: [String] = []
}
extension FileManager { var documentsDirectory: URL { FixtureStore.root } }
func minimuxerPairingProtocol() -> PairingProtocol { .unknown }
func debugLog(_ message: String) { FixtureStore.logs.append(message) }
enum FixtureFailure: Error { case failed }
func expect(_ value: @autoclosure () -> Bool) throws { if !value() { throw FixtureFailure.failed } }

enum FixtureHooks { static var onParse: (() -> Void)?; static var failUnlink = false }
import Darwin
func unlinkat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    if FixtureHooks.failUnlink && String(cString: path) == AppConstants.Pairing.lockdownPairingFileName {
        errno = EACCES; return -1
    }
    return Darwin.unlinkat(directory, path, flags)
}
final class FixtureCore {
    static var batchDepth = 0
    func beginTransportBatch() async { Self.batchDepth += 1 }
    func endTransportBatch() async { Self.batchDepth -= 1 }
}
final class FixtureGateway {
    static var failLive = false
    static var live = "fixture-device"
    static var cachedFetches = 0
    func fetchUDID() async throws -> String { Self.cachedFetches += 1; return "fixture-device" }
    func getLockdownValue(key: String) async throws -> String {
        try expect(key == "UniqueDeviceID")
        if Self.failLive { throw FixtureFailure.failed }
        return Self.live
    }
}
struct FixtureMinimuxer { let core = FixtureCore(); let gateway = FixtureGateway() }
let minimuxer = FixtureMinimuxer()
func ensureMinimuxerReady() async throws {}
