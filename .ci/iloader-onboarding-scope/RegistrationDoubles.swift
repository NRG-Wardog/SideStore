import Foundation

// Only side-effect boundaries are synthetic. registerCurrentDevice, pc1 capture,
// parser/validator and scoped observation bodies are extracted from production.
public struct ALTDevice: Sendable { let identifier: String }
public struct ALTDeviceType: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    static let all = Self(rawValue: 255)
    static let iphone = Self(rawValue: 1)
}
@MainActor final class UIDevice {
    static let current = UIDevice()
    var name: String { "SECRET_DEVICE_NAME_CANARY" }
}
final class CellularRefreshManager: @unchecked Sendable {
    static let shared = CellularRefreshManager()
    func turnOffDataIfNeeded() async { V3RegistrationFixture.current.record("cellOff") }
    func turnOnDataIfNeeded(addOnDelay: Double) async { V3RegistrationFixture.current.record("cellOn:\(addOnDelay)") }
}
final class V3RegistrationFixture: @unchecked Sendable {
    @TaskLocal static var current = V3RegistrationFixture()
    static let identifier = "SECRET_DEVICE_IDENTIFIER_CANARY"
    var live: Result<String, Error> = .success(identifier)
    var fallback: Result<String?, Error> = .success(identifier)
    var devices: Result<[ALTDevice], Error> = .success([ALTDevice(identifier: identifier)])
    var registered: Result<ALTDevice, Error> = .success(ALTDevice(identifier: identifier))
    var listHTTP: Int?
    var listResult: Int?
    var registerHTTP: Int?
    var registerResult: Int?
    var provider: String?
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.withLock { events.append(event) } }
    var log: [String] { lock.withLock { events } }
}
func fetchUDID() async throws -> String {
    let state = V3RegistrationFixture.current
    state.record("live")
    return try state.live.get()
}
func fetchUDID(useStatic: Bool) async throws -> String? {
    let state = V3RegistrationFixture.current
    state.record("fallback:\(useStatic)")
    return try state.fallback.get()
}
extension DeveloperPortalProxy {
    static var currentDeviceType: ALTDeviceType { .iphone }
    func fetchDevices(for team: ALTTeam, types: ALTDeviceType) async throws -> [ALTDevice] {
        let state = V3RegistrationFixture.current
        state.record("list:\(types.rawValue)")
        if let status = state.listHTTP { SideSignPortalDiagnostics.responseObserver?(status, state.provider) }
        if let result = state.listResult { SideSignPortalDiagnostics.resultCodeObserver?(result) }
        return try state.devices.get()
    }
    func registerDevice(name: String, identifier: String, type: ALTDeviceType, team: ALTTeam) async throws -> ALTDevice {
        let state = V3RegistrationFixture.current
        // Assert the actual unmodified portal arguments without exporting identifiers.
        precondition(name == "SECRET_DEVICE_NAME_CANARY" && identifier == V3RegistrationFixture.identifier && type == .iphone)
        state.record("register")
        if let status = state.registerHTTP { SideSignPortalDiagnostics.responseObserver?(status, state.provider) }
        if let result = state.registerResult { SideSignPortalDiagnostics.resultCodeObserver?(result) }
        return try state.registered.get()
    }
}

// Deliberately finite double of the proven public Minimuxer cases. No native code.
enum MinimuxerError: Error {
    case noDevice(String), noConnection(String), notReachable(String), noVPN(String), invalidVPN(String)
    case invalidPairing(String, String), notStarted(String), pairingNotLoaded(String), connectionModeNotConfigured(String)
    case createCoreDevice(String), createLockdown(String), getLockdownValue(String), connect(String), noService(String)
    case other(String)
}

final class V3CycleError: NSError, @unchecked Sendable {
    var next: Error?
    init() { super.init(domain: "SECRET_DOMAIN_CANARY", code: 777, userInfo: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var userInfo: [String: Any] {
        var value: [String: Any] = [NSLocalizedDescriptionKey: "SECRET_PASSWORD_TOKEN_CANARY"]
        if let next { value[NSUnderlyingErrorKey] = next }
        return value
    }
}
struct V3FixtureCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct MinimuxerServiceError: Error { let error: Error }
final class ALTWrappedError: NSError, @unchecked Sendable {
    let wrappedError: NSError
    init(error: NSError, userInfo: [String: Any]? = nil) {
        self.wrappedError = error
        super.init(domain: error.domain, code: error.code, userInfo: userInfo)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
