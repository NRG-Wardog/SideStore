import Foundation

enum LCAnisettePairError: Error { case orphanedBlob, invalidIdentifier, invalidBlob, migrationPairConflict }
enum TestError: Error { case read }
enum KeychainAccess {
    final class Keychain {
        var values: [String: Data] = [:]
        var reads = 0
        var writes = 0
        var failRead = false
        func getData(_ key: String) throws -> Data? {
            reads += 1
            if failRead { throw TestError.read }
            return values[key]
        }
    }
}
// ACTUAL_TYPES
struct LCEmbeddedSharedKeychain {
    static var installedGroup: String? = "selected"
    static let anisetteRecoveryJournal = "journal"
    static var items: [LCLegacyKeychainItem] = []
    static var enumerationHook: (() -> Void)?
    static var enumerations = 0
    static var locked = false
    static func withSharedTransaction<T>(_ body: () throws -> T) rethrows -> T {
        precondition(!locked)
        locked = true
        defer { locked = false }
        return try body()
    }
    static func legacyAnisetteItems() throws -> [LCLegacyKeychainItem] {
        precondition(locked)
        enumerations += 1
        enumerationHook?()
        return items
    }
    // ACTUAL_WRAPPER
}
@main struct LegacyComparisonHarness {
    static func main() async throws {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let blob = Data("SECRET_BLOB_CANARY".utf8)
        let pair = LCAnisetteStoredPair(identifier: Data(a.uuidString.utf8), blob: Data(blob.base64EncodedString().utf8))
        let snapshot = LCEmbeddedAnisetteSnapshot(identifier: a, adiBlob: blob, stored: pair)
        func item(_ key: String, _ value: Data, group: String = "SECRET_LEGACY_GROUP") -> LCLegacyKeychainItem {
            LCLegacyKeychainItem(group: group, key: key, data: value)
        }
        func compare(_ items: [LCLegacyKeychainItem]) -> LCAnisetteLegacyComparison {
            LCAnisetteLegacyComparison.compare(selected: pair, selectedGroup: "selected", items: items)
        }
        precondition(compare([]) == .init(identifier: .missing, blob: .missing))
        precondition(compare([item("identifier", Data(b.uuidString.utf8))]) == .init(identifier: .different, blob: .missing))
        precondition(compare([item("identifier", pair.identifier!), item("adiPb", pair.blob!)]) == .init(identifier: .equal, blob: .equal))
        let base64ID = withUnsafeBytes(of: a.uuid) { Data($0).base64EncodedString() }
        precondition(compare([item("identifier", Data(base64ID.utf8))]).identifier == .equal)
        precondition(compare([item("identifier", pair.identifier!), item("identifier", Data(b.uuidString.utf8), group: "second")]).identifier == .ambiguous)
        precondition(compare([item("identifier", pair.identifier!), item("identifier", Data(b.uuidString.utf8))]).identifier == .ambiguous)
        precondition(compare([item("identifier", Data("invalid".utf8))]).identifier == .unavailable)
        precondition(compare([item("adiPb", Data("%%%".utf8))]).blob == .unavailable)
        precondition(compare([item("adiPb", Data(Data("other".utf8).base64EncodedString().utf8))]).blob == .different)
        precondition(compare([item("identifier", pair.identifier!), item("adiPb", pair.blob!, group: "partial")]) == .init(identifier: .ambiguous, blob: .ambiguous))
        precondition(compare([item("identifier", Data(b.uuidString.utf8), group: "selected")]) == .init(identifier: .missing, blob: .missing))
        precondition(compare(Array(repeating: item("identifier", pair.identifier!), count: 65)) == .unavailable)
        precondition(compare([item("identifier", pair.identifier!), item("identifier", pair.identifier!)]) == .init(identifier: .equal, blob: .missing))
        precondition(compare([item("identifier", Data(repeating: 65, count: 129))]) == .unavailable)
        precondition(compare([item("adiPb", Data(repeating: 65, count: 1_398_105))]) == .unavailable)
        precondition(compare(Array(repeating: item("adiPb", Data(repeating: 65, count: 1_398_104)), count: 4)) == .unavailable)
        let client = KeychainAccess.Keychain()
        client.values = ["identifier": pair.identifier!, "adiPb": pair.blob!]
        let original = client.values
        LCEmbeddedSharedKeychain.items = [item("identifier", Data(b.uuidString.utf8))]
        let observed = try LCEmbeddedSharedKeychain.observeLegacyAnisetteComparison(for: snapshot, client: client)
        precondition(observed == .init(identifier: .different, blob: .missing))
        precondition(client.values == original && client.writes == 0)
        client.values["identifier"] = Data(b.uuidString.utf8)
        let stale = try LCEmbeddedSharedKeychain.observeLegacyAnisetteComparison(for: snapshot, client: client)
        precondition(stale == .unavailable)
        client.values = original
        LCEmbeddedSharedKeychain.enumerationHook = { client.values["identifier"] = Data(b.uuidString.utf8) }
        let raced = try LCEmbeddedSharedKeychain.observeLegacyAnisetteComparison(for: snapshot, client: client)
        precondition(raced == .unavailable)
        LCEmbeddedSharedKeychain.enumerationHook = nil
        client.values = original
        client.values["journal"] = Data([1])
        let pending = try LCEmbeddedSharedKeychain.observeLegacyAnisetteComparison(for: snapshot, client: client)
        precondition(pending == .unavailable)
        client.values = original
        client.failRead = true
        do { _ = try LCEmbeddedSharedKeychain.observeLegacyAnisetteComparison(for: snapshot, client: client); preconditionFailure() }
        catch TestError.read { }
        client.failRead = false
        let readsBefore = client.reads
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LCEmbeddedSharedKeychain.observeLegacyAnisetteComparison(for: snapshot, client: client)
        }
        do { _ = try await cancelled.value; preconditionFailure() }
        catch is CancellationError { }
        precondition(client.reads == readsBefore && client.writes == 0 && client.values == original)
        let publicOutput = observed.identifier.rawValue + "/" + observed.blob.rawValue
        precondition(publicOutput == "different/missing" && !publicOutput.contains("SECRET"))
        print("LEGACY_COMPARISON_READ_ONLY_PASS")
    }
}
