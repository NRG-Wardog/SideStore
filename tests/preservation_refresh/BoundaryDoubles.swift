// Only intended SDK edges exist: introducing registration/features/groups/signing
// calls in the actual production helper fails fixture compilation.
struct ALTTeam { let identifier: String }
struct FixtureAppID { let bundleIdentifier: String }
final class PortalProbe {
 static let shared = PortalProbe()
 var calls: [String] = []
 var appIDs = [FixtureAppID(bundleIdentifier: "app")]
 var candidate: ALTProvisioningProfile?
 var failDownload = false
}
final class AuthManager {
 static let shared = AuthManager()
 func getAuthenticatedTeam() async throws -> ALTTeam {
  PortalProbe.shared.calls.append("team"); return ALTTeam(identifier: "T")
 }
}
final class DeveloperPortalProxy {
 static let shared = DeveloperPortalProxy()
 static let currentDeviceType = "synthetic"
 func fetchAppIDs(for team: ALTTeam) async throws -> [FixtureAppID] {
  PortalProbe.shared.calls.append("lookup-existing-id"); return PortalProbe.shared.appIDs
 }
 func downloadProvisioningProfile(for id: FixtureAppID, deviceType: String, team: ALTTeam) async throws -> ALTProvisioningProfile {
  PortalProbe.shared.calls.append("generate-existing-id-profile")
  if PortalProbe.shared.failDownload { throw ProbeError.stopped }
  return PortalProbe.shared.candidate!
 }
}
