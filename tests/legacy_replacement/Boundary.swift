import Foundation
import CoreFoundation
import CryptoKit
// All storage/native objects below are inert boundary doubles. No installed
// signature, portal/network access or physical replacement is simulated as proof.
enum V3WireContract {
 static func strictBool(_ v:Any?)->Bool? { guard let n=v as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return nil};return n.boolValue }
}
struct CombinedFailure {
 enum Stage {case command,other};enum Code {case failed,other};enum Step {case refreshApplication,other}
 let operation:String;let stage:Stage;let code:Code;let sourceStep:Step;let signingContext:[String:String]
 static func decode(_ v:[String:Any],expectedID:String)->Self? {
  guard v["correlationID"] as? String == expectedID,let facts=v["signingContext"] as? [String:String] else{return nil}
  return .init(operation:v["operation"] as? String ?? "",stage:v["stage"] as? String == "command" ? .command:.other,code:v["code"] as? String == "failed" ? .failed:.other,sourceStep:v["sourceStep"] as? String == "refreshApplication" ? .refreshApplication:.other,signingContext:facts)
 }
}
enum CombinedVerification {
 static let uncertainMutationKey="uncertain"
 static func hasCompleteTerminalResults(_ m:[String:Any],runID:String)->Bool {
  guard m["run_id"] as? String == runID,let expected=m["expected_ids"] as? [String],!expected.isEmpty,let rows=m["results"] as? [[String:Any]] else{return false}
  return expected.count==Set(expected).count && rows.count==expected.count && Set(rows.compactMap{$0["bundle_id"] as? String})==Set(expected)
 }
}
final class Team {var identifier="TEAM"}
final class Ext {var bundleIdentifier="app.widget";var resignedBundleIdentifier="app.TEAM.widget"}
final class InstalledApp {
 var objectID="object";var isDeleted=false;var isActive=true;var useMainProfile=true
 var bundleIdentifier="app";var resignedBundleIdentifier="app.TEAM";var customBundleIdentifier:String?=nil
 var team:Team?=Team();var appBundleFingerprint:String?="legacy";var fileURL=URL(fileURLWithPath:"/fixture")
 var appExtensions=[Ext()];var certificateSerialNumber:String?="serial"
 var installedDate=Date(timeIntervalSince1970:1);var refreshedDate=Date(timeIntervalSince1970:2);var expirationDate=Date(timeIntervalSince1970:3)
}
var app=InstalledApp()
func v3Resolve<T>(_ target:String)throws->T {guard target=="target",let result=app as? T else{throw NSError(domain:"fixture",code:1)};return result}
final class Context {
 func performAndWait<T>(_ block:()throws->T)rethrows->T {try block()}
 func existingObject(with id:String)throws->Any {app}
}
final class Container {func newBackgroundContext()->Context{Context()}}
final class DatabaseManager {static let shared=DatabaseManager();let persistentContainer=Container();var team:Team?=Team();func activeTeam()->Team?{team}}
final class AuthManager {static let shared=AuthManager();var v3IdentityIsStable=true;var v3IdentityStamp="identity"}
enum StoreApp {static let altstoreAppID="host"}
final class ALTApplication {
 static var available=true;static var extensionIDs=["app.widget"]
 let bundleIdentifier:String;var appExtensions:[ALTApplication]{Self.extensionIDs.map{ALTApplication(id:$0)}}
 init(id:String){bundleIdentifier=id}
 convenience init?(fileURL:URL){guard Self.available else{return nil};self.init(id:"app")}
}
enum AppBundleFingerprint {
 static var digest:String?="strict";static var legacy:String?="legacy";static var calls:[String]=[]
 static func compute(for url:URL)->String?{calls.append("strict");return digest}
 static func computeOriginalCacheKey(for url:URL)->String?{calls.append("legacy");return legacy}
}
final class Cert {var serialNumber="serial";var data:Data?=Data([1,2,3]);var expiryDate=Date.distantFuture}
final class Signer {let x509=Cert()}
final class CertificateManager {
 static let shared=CertificateManager();var recorded:Cert?=Cert();var signer:Signer?=Signer()
 func getSigningCertificate(for app:InstalledApp)->Cert?{recorded}
 func getSignableCertificate(for serial:String)->Signer?{signer}
}
enum V3SharedAppGroup {
 static let defaults=UserDefaults(suiteName:"fixture-legacy-"+UUID().uuidString)!
 static func requireSharedUserDefaults()throws->UserDefaults{defaults}
}
final class Operations {var activeMutationID:String?=nil}
final class V3HeadlessRuntime {static let shared=V3HeadlessRuntime();let operations=Operations()}
enum V3OperationRecoveryJournal {
 static var held:String?=nil;static var directHeld:String?=nil
 static func current()throws->String?{held};static func direct()throws->String?{directHeld}
}
