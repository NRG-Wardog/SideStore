import Foundation
enum OperationError: Error { case invalidParameters(String) }
struct ALTEntitlement: Hashable { let rawValue:String; static let applicationIdentifier=Self(rawValue:"application-identifier") }
struct Cert { var serialNumber="S";var data:Data?=Data([1]);var expiryDate=Date.distantFuture }
struct SigningCertificate {var serialNumber="S";var x509=Cert()}
struct ALTProvisioningProfile {
 var uuid=UUID();var bundleIdentifier="signed.app";var teamIdentifier="T";var expirationDate=Date.distantFuture
 var certificates=[Cert()];var entitlements:[ALTEntitlement:Any]=[.applicationIdentifier:"PREFIX.signed.app"]
}
final class ALTApplication {
 static var sourceModel:ALTApplication?
 init() {}
 convenience init?(fileURL:URL) {self.init();guard let model=Self.sourceModel else{return nil};self.fileURL=fileURL;self.bundleIdentifier=model.bundleIdentifier;self.appExtensions=model.appExtensions}

 var bundleIdentifier="signed.app";var fileURL=URL(fileURLWithPath:"/synthetic")
 var appExtensions:[ALTApplication]=[];var provisioningProfile:ALTProvisioningProfile?=ALTProvisioningProfile()
 var entitlements:[ALTEntitlement:Any]=[.applicationIdentifier:"PREFIX.signed.app",ALTEntitlement(rawValue:"com.apple.developer.team-identifier"):"T"]
 var allAppBundles:[ALTApplication] {[self]+appExtensions}
}
final class CertificateManager {
 static let shared=CertificateManager();var certificate:Cert?=Cert()
 func getSigningCertificate(at:URL)->Cert? {certificate}
}
final class Handler {
 var legacyReplacementBinding:V3LegacyReplacementBinding?;var admission:(() async throws ->Void)?
 func validateLegacyReplacementAdmission()async throws {try await admission?()}
}
final class FixtureContext {
 var legacyReplacementBinding:V3LegacyReplacementBinding?;let handler=Handler()
 var bundleIdentifier="original.app";var customBundleIdentifier:String?;var targetBundleIdentifier:String {customBundleIdentifier ?? bundleIdentifier}
 var validateExtensionSigningCapabilities=false;var originalExtensionBundleIdentifiers:[String:String]=[:];var previouslyReusedExtensionIdentifiers:Set<String>=[]
 var useMainProfile=false;var validatedReuseMain=false;var overrideProvisioningProfile:ALTProvisioningProfile?
 var targetAppBundle:ALTApplication?;var temporaryDirectory=URL(fileURLWithPath:"/unused")
 var targetSigningCertificate:SigningCertificate?=SigningCertificate();var profileMutationAdmission:(()throws->Void)?
}

final class FixtureDB {
 var hasChanges=true;var saved=0;var fail=false
 func perform<T>(_ body:()throws->T) async rethrows ->T {try body()}
 func save()throws {saved+=1;if fail {throw OperationError.invalidParameters("synthetic")};hasChanges=false}
}

enum SignerError: Error { case invalidApp(cause:String) }
struct StrategyApp { var entitlements:[String:any Sendable] }
struct StrategyProfile { var teamIdentifier="T" }
final class StrategySigner {
 var observed:ExtensionSigningStrategy?; var required:[String:any Sendable]=[:];var signed:[String:any Sendable]=[:]
 func signApp(at:URL,provisioningProfiles:[ALTProvisioningProfile],progress:Progress?) async throws {
  _ = try await signApp(at:at,provisioningProfiles:provisioningProfiles,extensionStrategy:.perExtension,progress:progress)
 }
 func signApp(at:URL,provisioningProfiles:[ALTProvisioningProfile],extensionStrategy:ExtensionSigningStrategy,originalExtensionBundleIdentifiers:[String:String]=[:],previouslyReusedExtensionIdentifiers:Set<String>=[],progress:Progress?) async throws -> Bool {
  observed=extensionStrategy
  let app=StrategyApp(entitlements:required),matchedProfile=StrategyProfile(),filteredEntitlements=signed
  try actualSignerCapabilityGuard(extensionStrategy:extensionStrategy,app:app,matchedProfile:matchedProfile,filteredEntitlements:filteredEntitlements)
  return true
 }
}
