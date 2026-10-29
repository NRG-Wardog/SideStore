import Foundation
struct Cert { var serialNumber: String; var data: Data? }
struct ALTProvisioningProfile {
    var uuid: UUID; var data: Data; var bundleIdentifier: String
    var teamIdentifier: String; var expirationDate: Date; var certificates: [Cert]
}

extension ALTProvisioningProfile { init(data: Data) throws { throw NSError(domain:"SyntheticDecoderNotUsed",code:1) } }
