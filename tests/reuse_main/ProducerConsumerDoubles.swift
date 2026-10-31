// SDK representations only. Fingerprinting and registry/producers/consumer are production.
struct ALTEntitlement: Hashable, Sendable { let rawValue:String; static let applicationIdentifier=ALTEntitlement(rawValue:"application-identifier") }
struct FixtureCertificate: Sendable { let data:Data? }
struct ALTCertificate: Sendable { let x509:FixtureCertificate }
struct FixtureProfile { let uuid:UUID; let data:Data; let teamIdentifier:String; let certificates:[FixtureCertificate]; let entitlements:[ALTEntitlement:Any] }
@MainActor final class ALTApplication {
 let fileURL:URL
 var provisioningProfile:FixtureProfile?
 var entitlements:[ALTEntitlement:Any]=[:]
 var appExtensions:[ALTApplication]=[]
 var infoPlist:[String:Any] {
  guard let data=try? Data(contentsOf:fileURL.appendingPathComponent("Info.plist")),let p=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else { return [:] }; return p
 }
 var bundleIdentifier:String { infoPlist["CFBundleIdentifier"] as? String ?? "" }
 init(_ url:URL) { fileURL=url }
}
struct FixtureTeam: Sendable { let identifier:String }
struct FixtureExtension: Sendable { let bundleIdentifier:String; let resignedBundleIdentifier:String }
@MainActor final class InstalledApp {
 var bundleIdentifier:String;var resignedBundleIdentifier:String;var appBundleFingerprint:String?;let fileURL:URL
 var appExtensions:[FixtureExtension]=[];var team:FixtureTeam?=FixtureTeam(identifier:"TEAM");var useMainProfile=true
 init(_ original:String,_ resigned:String,_ source:URL) {bundleIdentifier=original;resignedBundleIdentifier=resigned;fileURL=source;appBundleFingerprint=AppBundleFingerprint.computeOriginalCacheKey(for:source)}
}
@MainActor final class FixtureContext {
 var bundleIdentifier:String;var appBundleFingerprint:String?;var validatedReuseMain=true;var useMainProfile=true
 var targetAppBundle:ALTApplication?
 var acknowledgedReuseMainIdentity:V3ValidatedReuseMainRegistry.AcknowledgedIdentity?
 init(_ app:InstalledApp) { bundleIdentifier=app.bundleIdentifier;appBundleFingerprint=app.appBundleFingerprint;targetAppBundle=ALTApplication(app.fileURL) }
}
@MainActor final class FixtureDB { func perform<T>(_ body:() -> T) async -> T { body() } }
@MainActor final class FixtureGroup { let dbContext=FixtureDB() }
