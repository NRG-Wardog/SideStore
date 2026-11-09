import Foundation
import CoreFoundation

// Only external database/network/certificate IO is substituted. The entire
// shipping health() function is inserted verbatim below.
struct Account { let appleID: String }
struct Team { let name: String }
final class DatabaseManager {
    static let shared = DatabaseManager()
    var account: Account?
    var team: Team?
    var isStarted = true
    func activeAccount() -> Account? { account }
    func activeTeam() -> Team? { team }
}
final class CertificateManager {
    static let shared = CertificateManager()
    var activeCertificate: String? = "fixture"
}
final class AnisetteServersManager {
    static let shared = AnisetteServersManager()
    func loadLocalServers() async -> [String] { [] }
    func getActiveServerURLs() async -> [String] { [] }
}
final class SideSignConfigManager {
    static let shared = SideSignConfigManager()
    func hasConfigFile() -> Bool { true }
}
enum Backend {
    static func hostSigningHealth() async -> [String: Any] {
        ["hostSigning": ["state": "fixture"], "identityStamp": "fixture"]
    }
    static func pairingFileStatus() -> String { "fixture" }
    static func certificateState() async -> [String: Any] { ["active": true] }
__PRODUCTION_HEALTH__
}

@main struct HealthSnapshotHarness {
    static func main() async throws {
        let db = DatabaseManager.shared
        for accountPresent in [false, true] {
            for teamPresent in [false, true] {
                // Display names deliberately equal fallback/localization keys.
                db.account = accountPresent ? Account(appleID: "Not signed in") : nil
                db.team = teamPresent ? Team(name: "No active team") : nil
                let result = await Backend.health()
                let data = try PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0)
                let wire = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
                for (key, expected) in [("activeAccountPresent", accountPresent), ("activeTeamPresent", teamPresent)] {
                    let number = wire[key] as! NSNumber
                    precondition(CFGetTypeID(number) == CFBooleanGetTypeID())
                    precondition(number.boolValue == expected)
                }
                precondition(wire["account"] as? String == "Not signed in")
                precondition(wire["team"] as? String == "No active team")
                precondition(wire["identityStamp"] as? String == "fixture")
                precondition((wire["hostSigning"] as? [String: String])?["state"] == "fixture")
                precondition(Set(wire.keys) == Set(["account", "team", "activeAccountPresent", "activeTeamPresent",
                    "certificate", "pairing", "anisette", "sidesign", "service", "certificateState", "hostSigning", "identityStamp"]))
            }
        }
        print("HEALTH_SNAPSHOT_CONTRACT_PASS")
    }
}
