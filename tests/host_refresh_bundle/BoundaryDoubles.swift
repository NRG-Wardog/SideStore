import Foundation
import Dispatch

// Only iOS/SideSign boundary types are doubled. Bundle IDs and extension
// enumeration come from real synthetic plists; copy, cleanup and the complete
// preservation fingerprint algorithm are the production implementations.
enum OperationError: Error { case invalidApp(reason: String); case invalidParameters(String) }
struct FixtureProfile { let uuid: UUID }
struct ALTApplication: Hashable, Sendable {
    let fileURL: URL
    let bundleIdentifier: String
    var appExtensions: Set<ALTApplication> {
        let children = (try? FileManager.default.contentsOfDirectory(at: fileURL.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Set(children.filter { $0.pathExtension.lowercased() == "appex" }.compactMap { ALTApplication(fileURL: $0) })
    }
    // Synthetic profile presence/identity only, not CMS or signing validation.
    var provisioningProfile: FixtureProfile? {
        guard (try? Data(contentsOf: fileURL.appendingPathComponent("embedded.mobileprovision"))) != nil else { return nil }
        return FixtureProfile(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000050")!)
    }
    var infoPlist: [String: Any] {
        guard let data = try? Data(contentsOf: fileURL.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return plist
    }
    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        self.fileURL = fileURL
        bundleIdentifier = identifier
    }
    func updateInfoPlist(with values: [String: String]) throws {
        let url = fileURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        for (key, value) in values { plist[key] = value }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
    }
}

struct InstalledExtension { let bundleIdentifier: String; let resignedBundleIdentifier: String }
final class InstalledApp {
    let fileURL: URL
    let bundleIdentifier: String
    let resignedBundleIdentifier: String
    var appExtensions: [InstalledExtension]
    let appBundleFingerprint = "preserve-existing-fingerprint"
    var useMainProfile = true
    let customBundleIdentifier: String? = "preserve-custom-id"
    init(fileURL: URL, bundleIdentifier: String, resignedBundleIdentifier: String,
         appExtensions: [InstalledExtension]) {
        self.fileURL = fileURL; self.bundleIdentifier = bundleIdentifier
        self.resignedBundleIdentifier = resignedBundleIdentifier; self.appExtensions = appExtensions
    }
}
enum AppOperation {
    case refresh(InstalledApp), other(InstalledApp)
    var app: Any { switch self { case .refresh(let app), .other(let app): return app } }
}
enum StoreApp { static let altstoreAppID = "com.fixture.host" }
extension Bundle {
    enum Info {
        nonisolated(unsafe) static var activeBundleIdentifier = "com.fixture.host.FIXTURETEAM"
        nonisolated(unsafe) static var activeBundleURL = URL(fileURLWithPath: "/fixture-not-configured")
    }
}
final class FixtureContext {
    var installedApp: InstalledApp?
    var appBundleFingerprint: String?
    var useMainProfile = false
    var validatedReuseMain = false
    var customBundleIdentifier: String?
    var targetAppBundle: ALTApplication?
}
enum V3RemoteRequestLeases {
    struct Admission { func check() throws {} }
    static let admitted: Admission? = Admission()
}
func lcStructuredSigningFailure(_ error: Error, stage: String, sourceStep: String?, facts: [String: String]) -> Error { error }
func lcRefreshFailureFacts(_ error: Error) -> [String: String] { [:] }
