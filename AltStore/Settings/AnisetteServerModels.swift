import Foundation
import SideSign

struct AnisetteServerData: Codable {
    let servers: [Server]
    let oda: ODAValue?

    enum CodingKeys: String, CodingKey {
        case servers
        case oda
    }

    init(servers: [Server], oda: ODAValue? = nil) {
        self.servers = servers
        self.oda = oda
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.servers = (try? container.decode([Server].self, forKey: .servers)) ?? []
        self.oda = try? container.decodeIfPresent(ODAValue.self, forKey: .oda)
    }
}

struct Server: Codable, Identifiable, Hashable {
    var id: String { address }
    var name: String
    var address: String
}
