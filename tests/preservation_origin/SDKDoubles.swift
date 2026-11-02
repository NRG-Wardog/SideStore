import Foundation
// Inert SDK dependencies. Full actual ProvisioningProfile and portal response
// decoders are compiled separately; certificate parsing is NOT claimed here.
public struct X509Certificate: Sendable { public init?(data:Data) { return nil } }
public struct ProfileType: RawRepresentable, Sendable {
 public let rawValue:String
 public init?(rawValue:String) { self.rawValue=rawValue }
 public init?(argument:String) { self.rawValue=argument }
}
public struct Team:Sendable { public let identifier:String }
public struct AppID:Sendable { public let identifier:String;public let bundleIdentifier:String }
public struct DeviceType:OptionSet,Sendable {
 public let rawValue:Int;public init(rawValue:Int){self.rawValue=rawValue}
 public static let iPhone=Self(rawValue:1),appleTV=Self(rawValue:2),mac=Self(rawValue:4),visionPro=Self(rawValue:8)
}
public struct Anisette:Sendable {
 public let machineID="fixture",oneTimePassword="fixture",localUserID="fixture",routingInfo="fixture",deviceID="fixture",clientInfo="fixture",clientTime="fixture",locale="fixture",timeZone="fixture"
}
public struct Session:Sendable {
 public let dsid="synthetic-account",authToken="not-a-token",xcodeVersion="fixture"
 public let anisetteData=Anisette()
 public var isValid=true
}
public struct SideSignHeaders:Sendable {
 public struct DeveloperServices:Sendable { public let userAgent="fixture" }
 public struct GrandSlam:Sendable { public let authApp="fixture" }
 public let developerServices=DeveloperServices(),grandSlam=GrandSlam()
}
public struct DeveloperPortal:Sendable { public let customHeaders=SideSignHeaders() }
enum Constants { enum DeveloperServices { static let clientID="fixture-client" } }
