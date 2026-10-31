import Foundation

// Extracted production registry plus this Foundation-only integration fixture.
// Models disk lifecycle (original -> staged signed -> ACK -> next refresh), not
// live-device observation. No synthetic generation is inserted into source cache.
@main struct Lifecycle {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("Payloads/source/App.app")
        let stagedURL = root.appendingPathComponent("Stage/App.app")
        try FileManager.default.createDirectory(at: originalURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalID = "fixture." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let signedID = originalID + ".TEAM"
        let extensions = [originalID + ".widget": signedID + ".widget"]
        let originalPlist: [String: Any] = ["CFBundleIdentifier": originalID]
        let originalBytes = try PropertyListSerialization.data(fromPropertyList: originalPlist, format: .binary, options: 0)
        try originalBytes.write(to: originalURL.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: originalURL, to: stagedURL)
        let generation = UUID().uuidString
        var signedPlist = originalPlist
        signedPlist["CFBundleIdentifier"] = signedID
        signedPlist[V3ValidatedReuseMainRegistry.generationKey] = generation
        try PropertyListSerialization.data(fromPropertyList: signedPlist, format: .binary, options: 0)
            .write(to: stagedURL.appendingPathComponent("Info.plist"))
        let record = V3ValidatedReuseMainRegistry.AcknowledgedIdentity(
            original: originalID, resigned: signedID, sourceFingerprint: "source-fingerprint", sourceDigest: "source-full-digest",
            profileUUID: UUID(), generation: generation, teamID: "TEAM", certificateDER: Data([1, 2, 3]),
            extensionIdentities: extensions, reusedExtensionIdentifiers: Set(extensions.values))
        func read(_ fingerprint: String? = "source-fingerprint", _ digest: String? = "source-full-digest",
                  team: String? = "TEAM", ext: [String: String]? = nil,
                  original: String? = nil, signed: String? = nil) -> V3ValidatedReuseMainRegistry.AcknowledgedIdentity? {
            V3ValidatedReuseMainRegistry.acknowledgedIdentity(original: original ?? originalID,
                resigned: signed ?? signedID, sourceFingerprint: fingerprint, sourceDigest: digest,
                teamID: team, extensionIdentities: ext ?? extensions)
        }
        precondition(record.isWellFormed)
        precondition(read() == nil, "signing/staging alone cannot enroll an installation")
        // Failure/lost ACK path does not call the acknowledgment API.
        precondition(read() == nil, "failed candidate remains unenrolled")
        V3ValidatedReuseMainRegistry.didAcknowledgeInstall(record, original: originalID, resigned: signedID)
        let sourceBytesAfter = try Data(contentsOf: originalURL.appendingPathComponent("Info.plist"))
        precondition(sourceBytesAfter == originalBytes, "original source cache must remain unchanged")
        let sourceAfter = try PropertyListSerialization.propertyList(from: sourceBytesAfter, format: nil) as! [String: Any]
        precondition(sourceAfter[V3ValidatedReuseMainRegistry.generationKey] == nil)
        precondition(!V3ValidatedReuseMainRegistry.contains(original: originalID, resigned: signedID,
            profileUUID: nil, generation: sourceAfter[V3ValidatedReuseMainRegistry.generationKey] as? String),
            "old consumer cannot recover generation from original source")
        precondition(read() == record, "new consumer recovers acknowledged history without altering source")
        precondition(read("changed") == nil)
        precondition(read(nil) == nil)
        precondition(read("source-fingerprint", "changed") == nil)
        precondition(read("source-fingerprint", nil) == nil)
        precondition(read(team: "OTHER") == nil)
        precondition(read(team: nil) == nil)
        precondition(read(ext: [:]) == nil)
        precondition(read(ext: [originalID + ".widget": signedID + ".different"]) == nil)
        precondition(read(original: "other") == nil)
        precondition(read(signed: "other") == nil)
        // A failed newer candidate must not erase the acknowledged prior record.
        precondition(read() == record)
        // A successfully acknowledged opt-out deliberately invalidates it.
        V3ValidatedReuseMainRegistry.didAcknowledgeInstall(nil, original: originalID, resigned: signedID)
        precondition(read() == nil)
        // V1 association alone is never silently promoted into V2 historical proof.
        V3ValidatedReuseMainRegistry.didInstall(original: originalID, resigned: signedID,
            profileUUID: record.profileUUID, generation: generation)
        precondition(read() == nil)
        V3ValidatedReuseMainRegistry.didAcknowledgeInstall(record, original: originalID, resigned: signedID)
        precondition(!V3ValidatedReuseMainRegistry.hasAssociation(original: originalID, resigned: signedID))
        precondition(read() == record)
        let malformed = V3ValidatedReuseMainRegistry.AcknowledgedIdentity(
            original: originalID, resigned: signedID, sourceFingerprint: "source-fingerprint", sourceDigest: "source-full-digest",
            profileUUID: UUID(), generation: "not-a-uuid", teamID: "TEAM", certificateDER: Data([1]),
            extensionIdentities: extensions, reusedExtensionIdentifiers: Set(extensions.values))
        precondition(!malformed.isWellFormed)
        V3ValidatedReuseMainRegistry.didAcknowledgeInstall(malformed, original: originalID, resigned: signedID)
        precondition(read() == nil, "bad acknowledged metadata must invalidate older evidence")
        V3ValidatedReuseMainRegistry.didAcknowledgeInstall(nil, original: originalID, resigned: signedID)
        print("PASS: original-source -> staged signing -> native ACK -> next refresh historical lookup; identity drift, failure, opt-out, V1 and malformed evidence controls")
    }
}
