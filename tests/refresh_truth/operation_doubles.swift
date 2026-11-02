import Foundation
import CoreFoundation
struct Cert { var serialNumber: String; var data: Data? }
struct ALTProvisioningProfile {
 var uuid: UUID; var data: Data; var bundleIdentifier: String; var teamIdentifier: String
 var expirationDate: Date; var certificates: [Cert]
 var entitlements: [ALTEntitlement:Any] = [:]
}
struct ALTEntitlement: Hashable { let rawValue: String; static let applicationIdentifier = ALTEntitlement(rawValue: "application-identifier") }
final class ALTApplication {
 var name = "Synthetic"; var bundleIdentifier = "app"
 var fileURL = Bundle.Info.activeBundleURL
 var appExtensions: [ALTApplication] = []; var entitlements: [ALTEntitlement:Any] = [:]
 var provisioningProfile: ALTProvisioningProfile?
 init() {}
 convenience init?(fileURL: URL) { guard let value = fixtureApplications[fileURL] else { return nil }; self.init(); bundleIdentifier=value.bundleIdentifier; self.fileURL=value.fileURL; appExtensions=value.appExtensions; entitlements=value.entitlements; provisioningProfile=value.provisioningProfile }
}
var fixtureApplications: [URL:ALTApplication] = [:]
var fixtureCertificates: [URL:Cert] = [:]
extension Bundle { enum Info { static var activeBundleURL = URL(fileURLWithPath: "/synthetic/Host.app"); static let activeBundleIdentifier = "app" } }
enum StoreApp { static let altstoreAppID = "host.original" }
final class CertificateManager { static let shared=CertificateManager(); func getSigningCertificate(at url:URL)->Cert? { fixtureCertificates[url] } }
enum OperationError: Error { case invalidParameters(String), noDevice, notReachable, unknownUDID }
enum ProbeError: Error { case stopped, installFailed, databaseFailed }
final class InstalledExtension {
 var bundleIdentifier = "app.ext"; var resignedBundleIdentifier = "app.ext"
 var expirationDate = Date(timeIntervalSince1970: 0)
 func update(provisioningProfile: ALTProvisioningProfile) { expirationDate = provisioningProfile.expirationDate }
}
struct FixtureStoredTeam { let identifier: String }
final class InstalledApp {
 var certificateSerialNumber: String? = "S"
 var team: FixtureStoredTeam? = FixtureStoredTeam(identifier: "T")
 let objectID = 1; var bundleIdentifier = "app"; var resignedBundleIdentifier = "app"
 var appExtensions: [InstalledExtension] = []; var certificateStatus = "valid"
 var expirationDate = Date(timeIntervalSince1970: 0)
 var useMainProfile = false
 func update(provisioningProfile: ALTProvisioningProfile) { expirationDate = provisioningProfile.expirationDate }
}
// CoreData is intentionally inert; the production operation keeps its exact type names.
typealias NSManagedObjectContext = DatabaseContext
final class DatabaseContext {
 var app = InstalledApp(); var performCount = 0; var failUpdate = false
 var hasChanges = true; var failSave = false
 var afterPerform: (() -> Void)?
 func save() throws { if failSave { throw ProbeError.databaseFailed } }
 func object(with id: Int) -> Any { app }
 func perform<T>(_ body: () throws -> T) async throws -> T {
  performCount += 1
  if failUpdate && performCount == 2 { throw ProbeError.databaseFailed }
  let value=try body();afterPerform?();return value
 }
}
struct PendingProfileBatch { var bundleID: String; var profiles:[Data]; var app:InstalledApp?; var certStatus:String? }
final class SharedContext { func addPendingProfileBatch(_ batch:PendingProfileBatch) {} }
final class InstallAppOperationContext {
 // Ordinary install fixture only. Replacement-specific gates run in their own
 // actual-source fixture; these defaults must never fabricate replacement proof.
 let legacyReplacementBinding: V3LegacyReplacementBinding? = nil
 func validateLegacyReplacementAdmission() async throws { precondition(legacyReplacementBinding == nil) }
 func validateLegacyReplacementBundle(_ app: FixtureSignedBundle, signed: Bool) throws { precondition(legacyReplacementBinding == nil) }

 var isPreservationRefresh = false
 var acknowledgedReuseMainIdentity: V3ValidatedReuseMainRegistry.AcknowledgedIdentity?
 var preservationRefreshState: V3PreservationRefreshState?
 var overrideProvisioningProfile: ALTProvisioningProfile?
 var provisioningProfiles: [String:ALTProvisioningProfile]?
 var targetAppBundle: ALTApplication? = ALTApplication()
 var dbBackgroundContext: NSManagedObjectContext = DatabaseContext()
 var isCellularRefreshGroup = false; var sharedContext = SharedContext()
 var bundleIdentifier = "app"; var targetBundleIdentifier = "app"
 var installedApp: InstalledApp?
 var targetCertStatus: String? = "valid"
 var useMainProfile = false; var validatedReuseMain = false
 var previouslyReusedExtensionIdentifiers: Set<String> = []
 var verifiedRefreshCertificate: (serial:String,data:Data,expiry:Date)?
 var profileMutationAdmission: (() throws -> Void)?
 var readInstalledProvisioningProfiles: (() async throws -> [Data])?
 var refreshVerification: V3RefreshVerification?
 var recordRefreshVerification: ((V3RefreshVerification)->Void)?
 init() { installedApp = dbBackgroundContext.app }
}
class BasePipelineOperation<C, R> {
 let context: C; var progress = Progress(totalUnitCount:100)
 init(context:C) { self.context=context }
 func execute(parentProgress:Progress?) async throws -> R { fatalError() }
 func executePreconditionCheck(parentProgress:Progress?) async throws {}
 func setProgress(_ value:Int64) { progress.completedUnitCount=value }
 func debugLog(_ value:String) {}
}
func CFAbsoluteTimeGetCurrent() -> Double { Date().timeIntervalSinceReferenceDate }
final class CellularRefreshManager {
 static let shared = CellularRefreshManager(); var duringOff: (() -> Void)?
 func turnOffDataIfNeeded() async { duringOff?() }
 func turnOnDataIfNeeded() async {}
}
enum V3RefreshFailureBoundary { case provisioningProfileInstallation,refreshRecordUpdate
 func preserving(_ error:Error) -> Error { error }
}
final class Injection { static let shared=Injection(); var count=0; var failAt=0; var after: (() -> Void)? }
func installProvisioningProfiles(_ data:Data) async throws {
 Injection.shared.count += 1
 if Injection.shared.count == Injection.shared.failAt { throw ProbeError.installFailed }
 Injection.shared.after?()
}
// Profile decoding is an inert lookup. The production operation and lifecycle
// execute unchanged; native profile parser/FFI qualification is a separate gate.
var fixtureProfiles: [Data:ALTProvisioningProfile] = [:]
extension ALTProvisioningProfile {
 init(data:Data) throws { guard let value=fixtureProfiles[data] else { throw ProbeError.stopped }; self=value }
}

struct V3PostMutationPersistenceError: Error {}
func debugLog(_ value:String) {}
struct FixtureSigningCertificate {
 let x509: FixtureX509
}
struct FixtureX509 { let serialNumber: String; let data: Data?; let expiryDate: Date }
struct FixtureSignedPiece { let provisioningProfile: ALTProvisioningProfile? }
struct FixtureSignedBundle { let allAppBundles: [FixtureSignedPiece]; let fileURL=URL(fileURLWithPath:"/synthetic/App.app") }
extension UserDefaults { var preferResignedIPA: Bool { true } }
final class InstallationHarness {
 let context: InstallAppOperationContext
 init(_ context:InstallAppOperationContext) { self.context=context }
 func handleSelfReinstallation(for app:InstalledApp) {}
 func installIPA(_ id:String) async throws { try await installProvisioningProfiles(Data()) }
 func installAppBundle(_ id:String,appName:String) async throws { try await installProvisioningProfiles(Data()) }
}

// Payload lookup only; exact production authorization policy is compiled separately.
var fixturePayloads: [Data: [String: Any]] = [:]
extension ALTProvisioningProfile {
 func propertyList() -> [String: Any] { fixturePayloads[data] ?? [:] }
}

// Inert CMS boundary only; the full production DER/XML decoder is extracted.
// Raw-only fixtures have no admitted values and therefore fail closed if a new
// semantic path is accidentally taken. No trust policy is simulated as proven.
enum ProfileCMSVerificationError: Error { case unsupportedSigner, signerTimeInvalid, verificationFailed, unsupportedRepresentation }
struct ProfileCMSSignerEvidence {
 enum Check: String { case unchecked, passed, failed }
 var algorithmAndAttributes: Check = .unchecked
 var pin: Check = .failed
 var chain: Check = .unchecked
 var temporal: Check = .unchecked
 var signature: Check = .unchecked
 var profileSubjectMarker = false
 var profileIssuerMarker = false
 var profileExtensionMarker = false
 var appDeveloperMarker = false
 var signerSHA256: String? = nil
}
// Test-only SDK result; production inspection has no caller-visible initializer.
// These bytes establish no cryptographic authority in this boundary fixture.
struct ProfileCMSCryptographicInspection {
 let untrustedContent: Data
 let signerSHA256: String
 let matchesApprovedSigner: Bool
}
enum FixtureCMSBoundary {
 static var outer: [Data: Data] = [:]
 static var inner: [Data: Data] = [:]
 static var calls = 0
 static var failure: ProfileCMSVerificationError?
 static var duringCall: (() -> Void)?
 static var innerFailures: [Data: ProfileCMSVerificationError] = [:]
 static var diagnostic = ProfileCMSSignerEvidence()
 static var diagnosticCalls = 0
 static var duringDiagnostic: (() -> Void)?
 static var inspectionFailures: [Data: ProfileCMSVerificationError] = [:]
 static var inspectionCalls = 0
 static var duringInspection: (() -> Void)?
 static func reset() { outer=[:];inner=[:];calls=0;failure=nil;duringCall=nil;innerFailures=[:];diagnostic=ProfileCMSSignerEvidence();diagnosticCalls=0;duringDiagnostic=nil;inspectionFailures=[:];inspectionCalls=0;duringInspection=nil }
}
enum ProfileCMSVerifier {
 static func authenticateOuter(_ data: Data) throws -> Data {
  FixtureCMSBoundary.calls += 1;FixtureCMSBoundary.duringCall?()
  if let error=FixtureCMSBoundary.failure { throw error }
  guard let result=FixtureCMSBoundary.outer[data] else { throw ProfileCMSVerificationError.unsupportedSigner }
  return result
 }
 static func diagnoseInnerSigner(_ data: Data) -> ProfileCMSSignerEvidence {
  FixtureCMSBoundary.diagnosticCalls += 1; FixtureCMSBoundary.duringDiagnostic?()
  return FixtureCMSBoundary.diagnostic
 }
 static func inspectInnerCryptography(_ data: Data) throws -> ProfileCMSCryptographicInspection {
  FixtureCMSBoundary.inspectionCalls += 1;FixtureCMSBoundary.duringInspection?()
  if let error=FixtureCMSBoundary.inspectionFailures[data] { throw error }
  if let error=FixtureCMSBoundary.failure { throw error }
  guard let content=FixtureCMSBoundary.inner[data] else { throw ProfileCMSVerificationError.verificationFailed }
  return ProfileCMSCryptographicInspection(untrustedContent:content,signerSHA256:String(repeating:"a",count:64),matchesApprovedSigner:false)
 }
 static func authenticateInner(_ data: Data) throws -> Data {
  FixtureCMSBoundary.calls += 1;FixtureCMSBoundary.duringCall?()
  if let error=FixtureCMSBoundary.innerFailures[data] { throw error }
  if let error=FixtureCMSBoundary.failure { throw error }
  guard let result=FixtureCMSBoundary.inner[data] else { throw ProfileCMSVerificationError.unsupportedSigner }
  return result
 }
}

// Shared test-only SDK capability shapes; actual mint is tested separately.
enum AppleProfileEvidenceError: String, Error, Sendable { case unavailable, invalidResponse, responseTooLarge, identityMismatch, ambiguousProfile, recordNotFound, cancelled, expiredOperation, ownershipChanged }
final class AppleProfileEvidence: @unchecked Sendable {
 enum Role { case existing, candidate }
 let profile: ALTProvisioningProfile
 let role: Role
 let operationID: UUID
 var cmsData: Data { profile.data }
 init(profile:ALTProvisioningProfile,role:Role,operationID:UUID) {
  self.profile=profile;self.role=role;self.operationID=operationID
 }
}
final class AppleProfileOperation: @unchecked Sendable {
 let id=UUID(); let target:String; let admission:() throws->Void
 var active=true
 init(target:String,admission:@escaping () throws->Void) { self.target=target;self.admission=admission }
 var onInvalidate:(()->Void)?
 func invalidate() { if active {onInvalidate?()};active=false }
 func authorize(_ evidence:AppleProfileEvidence,exactCMS:Data) throws {
  try admission()
  guard active else { throw AppleProfileEvidenceError.expiredOperation }
  guard evidence.operationID==id,evidence.cmsData==exactCMS,evidence.profile.bundleIdentifier==target else { throw AppleProfileEvidenceError.identityMismatch }
 }
}

// Real preservation wrapper is extracted from MinimuxerWrapper.swift. Only its
// core/device boundary is fake. Any accidental retry-helper entry is observed.
enum MinimuxerError: Error { case noDevice, notReachable }
enum FixturePreservationTransport {
 static var coreCalls=0
 static var retryEntries=0
 static var portChanges=0
 static var failure:Error?
 static func reset(){coreCalls=0;retryEntries=0;portChanges=0;failure=nil}
}
struct FixturePreservationCore {
 func installProvisioningProfile(profile:Data) async throws {
  FixturePreservationTransport.coreCalls += 1
  if let error=FixturePreservationTransport.failure {Injection.shared.count += 1;throw error}
  try await installProvisioningProfiles(profile)
 }
}
enum minimuxer { static let core=FixturePreservationCore() }
func withRemotePairingRetry<T>(_ operation:() async throws->T) async throws->T {
 FixturePreservationTransport.retryEntries += 1
 FixturePreservationTransport.portChanges += 1
 return try await operation()
}
