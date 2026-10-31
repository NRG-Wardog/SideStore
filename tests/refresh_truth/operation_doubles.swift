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
enum OperationError: Error { case invalidParameters(String) }
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
 func save() throws { if failSave { throw ProbeError.databaseFailed } }
 func object(with id: Int) -> Any { app }
 func perform<T>(_ body: () throws -> T) async throws -> T {
  performCount += 1
  if failUpdate && performCount == 2 { throw ProbeError.databaseFailed }
  return try body()
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
