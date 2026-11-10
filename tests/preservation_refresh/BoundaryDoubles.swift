// Only intended SDK edges exist: introducing registration/features/groups/signing
// calls in the actual production helper fails fixture compilation.
struct ALTTeam { let identifier: String }
struct FixtureAppID { let bundleIdentifier: String }
typealias ALTAppID = FixtureAppID
enum AppIDLookupError: String, Error, CaseIterable {
 case invalidHTTPResponse, httpFailure, missingStatus, unsuccessfulStatus
 case missingList, nullList, malformedList, malformedRecord, conflictingRecord
}
final class PortalProbe {
 static let shared = PortalProbe()
 var calls: [String] = []
 var appIDs = [FixtureAppID(bundleIdentifier: "app")]
 var candidate: ALTProvisioningProfile?
 var failDownload = false
 var existingProfiles:[UUID:ALTProvisioningProfile]=[:]
 var failCorroboration=false
 var afterList:(()->Void)?
 var afterExisting:(()->Void)?
 var afterGeneration:(()->Void)?
 var wrongCandidateOperation=false
 var corroboratedUUIDs:[UUID]=[]
 var originInvalidations=0
 var lastOriginOperation:AppleProfileOperation?
 var lookupFailure:Error?
 var afterIDLookup:(()->Void)?
 func resetOrigin() { existingProfiles=[:];failCorroboration=false;afterList=nil;afterExisting=nil;afterGeneration=nil;wrongCandidateOperation=false;originInvalidations=0;lastOriginOperation=nil;corroboratedUUIDs=[];lookupFailure=nil;afterIDLookup=nil }
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
 func fetchAppIDsPreservingIdentity(for team: ALTTeam) async throws -> [FixtureAppID] {
  PortalProbe.shared.calls.append("lookup-existing-id")
  await Task.yield();PortalProbe.shared.afterIDLookup?()
  if let error=PortalProbe.shared.lookupFailure { throw error }
  return PortalProbe.shared.appIDs
 }
 func downloadProvisioningProfile(for id: FixtureAppID, deviceType: String, team: ALTTeam) async throws -> ALTProvisioningProfile {
  PortalProbe.shared.calls.append("generate-existing-id-profile")
  if PortalProbe.shared.failDownload { throw ProbeError.stopped }
  return PortalProbe.shared.candidate!
 }
}

// Explicit SDK-boundary doubles only. Actual non-forgeable minting and transport
// run separately in preservation_origin; these are never production exports.
extension AppleProfileOperation {
 func corroborateExisting(installedCMS:Data,uuid:UUID,bundleIdentifier:String) async throws->AppleProfileEvidence {
  try admission();PortalProbe.shared.corroboratedUUIDs.append(uuid);PortalProbe.shared.calls.append("list-existing-profiles")
  if PortalProbe.shared.failCorroboration { throw AppleProfileEvidenceError.unavailable }
  await Task.yield();PortalProbe.shared.afterList?();try admission()
  guard active, bundleIdentifier==target,let p=PortalProbe.shared.existingProfiles[uuid],p.data==installedCMS else { throw AppleProfileEvidenceError.identityMismatch }
  PortalProbe.shared.calls.append("download-exact-existing-profile")
  await Task.yield();PortalProbe.shared.afterExisting?();try admission()
  guard active else { throw AppleProfileEvidenceError.expiredOperation }
  return AppleProfileEvidence(profile:p,role:.existing,operationID:id)
 }
 func generateCandidate(for appID:FixtureAppID,deviceType:String) async throws->AppleProfileEvidence {
  try admission();guard active,appID.bundleIdentifier==target else { throw AppleProfileEvidenceError.identityMismatch }
  PortalProbe.shared.calls.append("generate-existing-id-profile")
  if PortalProbe.shared.failDownload { throw ProbeError.stopped }
  await Task.yield();PortalProbe.shared.afterGeneration?();try admission()
  guard active,let p=PortalProbe.shared.candidate else { throw AppleProfileEvidenceError.unavailable }
  return AppleProfileEvidence(profile:p,role:.candidate,operationID:PortalProbe.shared.wrongCandidateOperation ? UUID():id)
 }
}
extension DeveloperPortalProxy {
 func makePreservationProfileOperation(team:ALTTeam,bundleIdentifier:String,admission:@escaping () throws->Void) async throws->AppleProfileOperation {
  try admission();PortalProbe.shared.calls.append("origin-operation")
  let op=AppleProfileOperation(target:bundleIdentifier,admission:admission);op.onInvalidate={PortalProbe.shared.originInvalidations += 1};PortalProbe.shared.lastOriginOperation=op;return op
 }
}
