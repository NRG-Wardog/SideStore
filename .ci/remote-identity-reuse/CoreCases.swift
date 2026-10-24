import Foundation
import Security

let fixtureCredentialsA = LCEmbeddedAuthenticationSnapshot(
    appleIDEmailAddress: "first@example.invalid", appleIDPassword: "synthetic-password-a",
    appleIDAdsid: "synthetic-dsid-a", appleIDXcodeToken: "synthetic-token-a")
let fixtureCredentialsB = LCEmbeddedAuthenticationSnapshot(
    appleIDEmailAddress: "second@example.invalid", appleIDPassword: "synthetic-password-b",
    appleIDAdsid: "synthetic-dsid-b", appleIDXcodeToken: "synthetic-token-b")

func fixtureBinding(_ credentials: LCEmbeddedAuthenticationSnapshot) throws -> Data {
    try V3RemoteIdentityRecord.credentialBinding(appleID: credentials.appleIDEmailAddress,
        dsid: credentials.appleIDAdsid, token: credentials.appleIDXcodeToken)
}

func fixtureRecord(binding: Data? = nil, identity: Data = Data(repeating: 0x17, count: 16),
                   blob: String = Data("synthetic-provider-provisioning-record".utf8).base64EncodedString(),
                   endpoint: String = V3RemoteIdentityRecord.allowedEndpoint,
                   schema: Int = 1, id: String = "12345678-1234-4321-ABCD-0123456789AB") -> V3RemoteIdentityRecord {
    V3RemoteIdentityRecord(schemaVersion: schema, identityID: id, endpoint: endpoint,
                           identity: identity, adiPB: blob, routeBinding: binding)
}

func fixtureEncode(_ record: V3RemoteIdentityRecord) throws -> Data {
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    return try encoder.encode(record)
}

func fixtureMap(_ record: V3RemoteIdentityRecord) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: fixtureEncode(record), options: [], format: nil) as! [String: Any]
}

func fixtureData(_ map: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: map, format: .binary, options: 0)
}

func fixtureSave(_ record: V3RemoteIdentityRecord, credentials: LCEmbeddedAuthenticationSnapshot = fixtureCredentialsA,
                 replacing old: V3RemoteIdentityRecord? = nil, keychain: Keychain = .shared) throws {
    let route = try fixtureWriteCredentials(credentials, keychain: keychain)
    try keychain.commitRemoteIdentity(record, replacing: old, credentials: credentials, expectedRoute: route)
}

func fixtureWriteCredentials(_ credentials: LCEmbeddedAuthenticationSnapshot,
                             keychain: Keychain = .shared) throws -> Data {
    try keychain.writeAuthenticationCredentials(appleID: credentials.appleIDEmailAddress!,
        password: credentials.appleIDPassword!, dsid: credentials.appleIDAdsid!,
        authToken: credentials.appleIDXcodeToken!, remoteProvider: true)
    return try keychain.remoteIdentityRouteBytes()!
}

func runCoreCases() throws -> [String] {
    var passed: [String] = []
    func test(_ name: String, _ body: () throws -> Void) throws {
        fixtureReset(); try body(); passed.append(name)
    }

    try test("missing_store_is_not_a_new_identity") {
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "missing")
        try fixtureCheck(FixtureSecurity.shared.queries().count == 1, "read only")
    }
    try test("protected_store_restart_reuses_exact_identity") {
        let saved = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        try fixtureSave(saved)
        let restartedClient = Keychain()
        try fixtureCheck(try restartedClient.remoteIdentityRecord() == saved, "restarted client")
        try fixtureCheck(try restartedClient.remoteIdentityRecord()?.identity == saved.identity, "identity retained")
    }
    try test("credential_binding_is_normalized_and_length_delimited") {
        let normalized = try V3RemoteIdentityRecord.credentialBinding(
            appleID: "  FIRST@EXAMPLE.INVALID\n", dsid: "synthetic-dsid-a", token: "synthetic-token-a")
        try fixtureCheck(normalized == fixtureBinding(fixtureCredentialsA), "normalization")
        let left = try V3RemoteIdentityRecord.credentialBinding(appleID: "a", dsid: "bc", token: "d")
        let right = try V3RemoteIdentityRecord.credentialBinding(appleID: "ab", dsid: "c", token: "d")
        try fixtureCheck(left != right && left.count == 32, "unambiguous digest")
        for missing in [nil, "", " \n"] as [String?] {
            try fixtureThrows("empty account") {
                _ = try V3RemoteIdentityRecord.credentialBinding(appleID: missing, dsid: "d", token: "t")
            }
        }
        try fixtureThrows("missing token") {
            _ = try V3RemoteIdentityRecord.credentialBinding(appleID: "a", dsid: "d", token: nil)
        }
    }
    try test("account_authorization_is_separate_from_provider_identity") {
        let first = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        try fixtureSave(first)
        var second = first; second.routeBinding = try fixtureBinding(fixtureCredentialsB)
        try fixtureSave(second, credentials: fixtureCredentialsB, replacing: first)
        let loaded = try Keychain.shared.remoteIdentityRecord()
        try fixtureCheck(loaded == second, "account replacement")
        try fixtureCheck(loaded?.identity == first.identity && loaded?.adiPB == first.adiPB, "stable provider")
        try fixtureCheck(second.routeBinding != first.routeBinding, "distinct account route")
    }
    try test("old_credential_commit_cannot_replace_new_account") {
        let old = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        try fixtureSave(old)
        try fixtureInstallCredentials(fixtureCredentialsB)
        try fixtureThrows("stale account") {
            try Keychain.shared.commitRemoteIdentity(old, replacing: old, credentials: fixtureCredentialsA,
                expectedRoute: Keychain.shared.remoteIdentityRouteBytes()!)
        }
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == old, "preserve state")
    }
    try test("route_digest_must_match_current_credentials") {
        let wrong = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsB))
        let route = try fixtureWriteCredentials(fixtureCredentialsA)
        try fixtureThrows("foreign route") {
            try Keychain.shared.commitRemoteIdentity(wrong, replacing: nil, credentials: fixtureCredentialsA, expectedRoute: route)
        }
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "not published")
    }
    try test("concurrent_compare_and_swap_has_one_winner") {
        let old = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        try fixtureSave(old)
        var next = old; next.routeBinding = try fixtureBinding(fixtureCredentialsB)
        let route = try fixtureWriteCredentials(fixtureCredentialsB)
        let nextRecord = next
        let lock = NSLock(); var successes = 0; var changed = 0; var other = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                try Keychain.shared.commitRemoteIdentity(nextRecord, replacing: old, credentials: fixtureCredentialsB, expectedRoute: route)
                lock.lock(); successes += 1; lock.unlock()
            } catch V3RemoteIdentityError.stateChanged {
                lock.lock(); changed += 1; lock.unlock()
            } catch { lock.lock(); other += 1; lock.unlock() }
        }
        try fixtureCheck(successes == 1 && changed == 31 && other == 0, "serialized CAS")
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nextRecord, "winner retained")
    }
    try test("ordinary_signout_retains_identity_and_revokes_route") {
        let saved = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        try fixtureSave(saved)
        let localID = Data("synthetic-old-local-identifier".utf8)
        let localBlob = Data("synthetic-old-android-blob".utf8)
        try Keychain.shared.keychain.set(localID, key: "identifier")
        try Keychain.shared.keychain.set(localBlob, key: "adiPb")
        try LCEmbeddedSharedKeychain.clearSignInInfoChecked(Keychain.shared.keychain)
        let retained = saved
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == retained, "identity retained")
        for key in LCSharedKeychainMigration.authKeys {
            try fixtureCheck(try Keychain.shared.keychain.getData(key) == nil, "credentials removed")
        }
        try fixtureCheck(try Keychain.shared.keychain.getData("identifier") == localID, "old identity untouched")
        try fixtureCheck(try Keychain.shared.keychain.getData("adiPb") == localBlob, "old blob untouched")
        try fixtureThrows("late signout commit") {
            try Keychain.shared.commitRemoteIdentity(saved, replacing: retained, credentials: fixtureCredentialsA,
                expectedRoute: Keychain.shared.remoteIdentityRouteBytes()!)
        }
    }
    try test("same_identity_can_authorize_new_account_after_signout") {
        let saved = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        try fixtureSave(saved)
        try LCEmbeddedSharedKeychain.clearSignInInfoChecked(Keychain.shared.keychain)
        let retained = try Keychain.shared.remoteIdentityRecord()!
        var next = retained; next.routeBinding = try fixtureBinding(fixtureCredentialsB)
        try fixtureSave(next, credentials: fixtureCredentialsB, replacing: retained)
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord()?.identity == saved.identity, "same identity")
    }
    try test("explicit_reset_removes_only_remote_identity") {
        let saved = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        try fixtureSave(saved)
        try Keychain.shared.keychain.set(Data("local-unchanged".utf8), key: "adiPb")
        try Keychain.shared.resetRemoteIdentity()
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "removed")
        try fixtureCheck(try Keychain.shared.keychain.getData("adiPb") == Data("local-unchanged".utf8), "local retained")
        try fixtureCheck(try Keychain.shared.keychain.getData("appleIDXcodeToken") != nil, "unrelated credential retained")
        try fixtureCheck(try Keychain.shared.remoteIdentityRouteMarker()?.mode == .readyRemote, "route provenance retained")
        try Keychain.shared.resetRemoteIdentity()
    }
    try test("explicit_reset_can_remove_malformed_identity") {
        let corrupt = Data("synthetic-corrupt-record".utf8)
        FixtureSecurity.shared.seed(service: "fixture.container.remote-anisette", group: "fixture.entitled.group",
                                    account: "mac-jkcoxson-v1", bytes: corrupt)
        try fixtureThrowsRemote("corrupt ordinary read", expected: .invalidRecord) {
            _ = try Keychain.shared.remoteIdentityRecord()
        }
        try Keychain.shared.resetRemoteIdentity()
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "corrupt reset verified")
    }
    try test("protected_route_marker_is_bounded_and_redacted") {
        let binding = try fixtureBinding(fixtureCredentialsA)
        for mode in [V3RemoteRouteMarker.Mode.local, .pendingRemote, .readyRemote] {
            let marker = try V3RemoteRouteMarker(mode: mode, binding: binding)
            try fixtureCheck(marker.encoded.count == 69, "bounded marker")
            try fixtureCheck(try V3RemoteRouteMarker(data: marker.encoded) == marker, "marker round trip")
            try fixtureCheck(!String(describing: marker).contains(binding.base64EncodedString()), "redacted marker")
            try fixtureCheck(!String(reflecting: marker).contains(binding.base64EncodedString()), "redacted debug marker")
        }
        for bytes in [Data(), Data(repeating: 0, count: 33), Data(repeating: 0, count: 68),
                      Data(repeating: 0, count: 70), Data([9]) + binding + Data(UUID().uuidString.utf8),
                      Data([2]) + binding + Data(repeating: 0x78, count: 36)] {
            try fixtureThrowsRemote("malformed marker", expected: .invalidRecord) {
                _ = try V3RemoteRouteMarker(data: bytes)
            }
        }
        let first = try V3RemoteRouteMarker(mode: .pendingRemote, binding: binding)
        let second = try V3RemoteRouteMarker(mode: .pendingRemote, binding: binding)
        try fixtureCheck(first.generation != second.generation, "fresh route generation")
    }
    try test("endpoint_and_namespace_separation") {
        let foreign = fixtureRecord(endpoint: "https://different-provider.invalid")
        try fixtureThrows("provider mismatch") { try foreign.validated() }
        let bytes = try fixtureEncode(fixtureRecord())
        FixtureSecurity.shared.seed(service: "fixture.container", group: "fixture.entitled.group",
                                    account: "identifier", bytes: bytes)
        FixtureSecurity.shared.seed(service: "fixture.container.remote-anisette", group: "other.group",
                                    account: "mac-jkcoxson-v1", bytes: bytes)
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "foreign records ignored")
    }
    try test("route_update_cannot_rotate_identity_blob_or_record_id") {
        let old = fixtureRecord(); var store: Data? = try fixtureEncode(old)
        let invalid = [fixtureRecord(identity: Data(repeating: 0x29, count: 16)),
                       fixtureRecord(blob: Data("different synthetic blob".utf8).base64EncodedString()),
                       fixtureRecord(id: "22345678-1234-4321-ABCD-0123456789AB")]
        for next in invalid {
            try fixtureThrows("implicit identity rotation") {
                try V3RemoteIdentityRecordIO.write(next, replacing: old, load: { store }, save: { store = $0 })
            }
            try fixtureCheck(try V3RemoteIdentityRecordIO.read { store } == old, "preserve identity")
        }
    }
    try test("malformed_record_fields_fail_closed") {
        let invalid = [fixtureRecord(schema: 0), fixtureRecord(schema: 2), fixtureRecord(id: "not-a-uuid"),
                       fixtureRecord(identity: Data()), fixtureRecord(identity: Data(repeating: 0, count: 15)),
                       fixtureRecord(identity: Data(repeating: 0, count: 17)), fixtureRecord(blob: ""),
                       fixtureRecord(blob: "not-base64"), fixtureRecord(blob: "Zh=="),
                       fixtureRecord(binding: Data(repeating: 0, count: 31)),
                       fixtureRecord(binding: Data(repeating: 0, count: 33))]
        for record in invalid {
            let bytes = try fixtureEncode(record)
            try fixtureThrows("invalid field") { _ = try V3RemoteIdentityRecordIO.read { bytes } }
        }
    }
    try test("malformed_unknown_missing_and_oversized_storage_rejected") {
        var unknown = try fixtureMap(fixtureRecord()); unknown["secretToken"] = "synthetic-only"
        var missing = try fixtureMap(fixtureRecord()); missing.removeValue(forKey: "identityID")
        let invalid = [try fixtureData(unknown), try fixtureData(missing), Data("not a plist".utf8),
                       Data(repeating: 0x31, count: 9_000_001)]
        for bytes in invalid {
            try fixtureThrowsRemote("untrusted storage", expected: .invalidRecord) {
                _ = try V3RemoteIdentityRecordIO.read { bytes }
            }
        }
    }
    try test("write_and_remove_require_expected_current_record") {
        let saved = fixtureRecord(); var store: Data? = try fixtureEncode(saved)
        try fixtureThrows("stale create") {
            try V3RemoteIdentityRecordIO.write(saved, replacing: nil, load: { store }, save: { store = $0 })
        }
        var stale = saved; stale.routeBinding = Data(repeating: 0x42, count: 32)
        try fixtureThrows("stale remove") {
            try V3RemoteIdentityRecordIO.remove(stale, load: { store }, remove: { store = nil })
        }
        try fixtureCheck(try V3RemoteIdentityRecordIO.read { store } == saved, "no lost update")
    }
    try test("protected_adapter_query_attributes_are_exact") {
        let saved = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        try fixtureSave(saved)
        try Keychain.shared.resetRemoteIdentity()
        let queries = FixtureSecurity.shared.queries()
        try fixtureCheck(queries.count > 5, "all operations captured")
        for query in queries {
            try fixtureCheck(query[kSecClass] as? String == kSecClassGenericPassword as String, "generic password")
            try fixtureCheck(query[kSecAttrService] as? String == "fixture.container.remote-anisette", "separate service")
            try fixtureCheck(query[kSecAttrAccessGroup] as? String == "fixture.entitled.group", "entitled access group")
            try fixtureCheck(["mac-jkcoxson-v1", "mac-jkcoxson-route-v1"].contains(query[kSecAttrAccount] as? String ?? ""), "provider account key")
            try fixtureCheck(query[kSecAttrSynchronizable] as? Bool == false, "not synchronizable")
            try fixtureCheck(query[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "device only")
            try fixtureCheck(query[kSecUseDataProtectionKeychain] as? Bool == true, "data protection")
        }
    }
    try test("missing_entitlement_or_service_never_falls_back") {
        LCEmbeddedSharedKeychain.installedGroup = nil
        try fixtureThrows("missing group") { _ = try Keychain.shared.remoteIdentityRecord() }
        LCEmbeddedSharedKeychain.installedGroup = "fixture.entitled.group"
        LCEmbeddedSharedKeychain.service = ""
        try fixtureThrows("missing service") { _ = try Keychain.shared.remoteIdentityRecord() }
        try fixtureCheck(FixtureSecurity.shared.queries().isEmpty, "no fallback query")
    }
    try test("failed_storage_read_does_not_mean_missing_identity") {
        FixtureSecurity.shared.failReads = true
        try fixtureThrowsRemote("read error", expected: .storageUnverified) {
            _ = try Keychain.shared.remoteIdentityRecord()
        }
    }
    try test("write_failure_is_not_reported_as_success") {
        FixtureSecurity.shared.failWrites = true
        try fixtureThrows("write error") { try fixtureSave(fixtureRecord(binding: fixtureBinding(fixtureCredentialsA))) }
        FixtureSecurity.shared.failWrites = false
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "no saved identity")
    }
    try test("unverified_write_readback_fails_closed") {
        FixtureSecurity.shared.ignoreWrites = true
        try fixtureThrows("ignored write") { try fixtureSave(fixtureRecord(binding: fixtureBinding(fixtureCredentialsA))) }
    }
    try test("remove_failure_and_unverified_readback_fail_closed") {
        let saved = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(saved)
        FixtureSecurity.shared.failRemoves = true
        try fixtureThrows("failed remove") { try Keychain.shared.resetRemoteIdentity() }
        FixtureSecurity.shared.failRemoves = false; FixtureSecurity.shared.ignoreRemoves = true
        try fixtureThrows("ignored remove") { try Keychain.shared.resetRemoteIdentity() }
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == saved, "identity retained")
    }
    try test("signout_succeeds_without_reading_or_mutating_remote_store") {
        let saved = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(saved)
        let marker = try Keychain.shared.remoteIdentityRouteBytes()
        let before = FixtureSecurity.shared.queries().count
        FixtureSecurity.shared.failWrites = true; FixtureSecurity.shared.failReads = true
        try LCEmbeddedSharedKeychain.clearSignInInfoChecked(Keychain.shared.keychain)
        try fixtureCheck(FixtureSecurity.shared.queries().count == before, "signout independent of remote storage")
        try fixtureCheck(try Keychain.shared.keychain.getData("appleIDXcodeToken") == nil, "credential authority removed")
        FixtureSecurity.shared.failWrites = false; FixtureSecurity.shared.failReads = false
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == saved, "state retained")
        try fixtureCheck(try Keychain.shared.remoteIdentityRouteBytes() == marker, "inert provenance retained")
    }
    try test("stored_record_contains_no_copied_account_credentials") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        let map = try fixtureMap(record)
        try fixtureCheck(Set(map.keys) == Set(["schemaVersion", "identityID", "endpoint", "identity", "adiPB", "routeBinding"]), "bounded record schema")
        let text = String(describing: map)
        for secret in [fixtureCredentialsA.appleIDEmailAddress!, fixtureCredentialsA.appleIDPassword!,
                       fixtureCredentialsA.appleIDAdsid!, fixtureCredentialsA.appleIDXcodeToken!] {
            try fixtureCheck(!text.contains(secret), "no credential duplication")
        }
    }
    try test("diagnostics_are_constant_and_redacted") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA))
        let messages = [String(describing: record), String(reflecting: record)] +
            [V3RemoteIdentityError.invalidRecord, .storageUnverified, .stateChanged,
             .manualSignInRequired].map { $0.localizedDescription }
        let forbidden = [record.identityID, record.adiPB, record.identity.base64EncodedString(),
                         record.routeBinding!.base64EncodedString(), fixtureCredentialsA.appleIDXcodeToken!]
        for message in messages {
            for secret in forbidden { try fixtureCheck(!message.contains(secret), "safe diagnostics") }
        }
    }
    try test("remote_identity_error_bridge_uses_finite_domain_and_codes") {
        let values: [(V3RemoteIdentityError, Int)] = [(.invalidRecord, 1), (.storageUnverified, 2),
            (.stateChanged, 3), (.manualSignInRequired, 4)]
        for (error, expected) in values {
            let bridged = error as NSError
            try fixtureCheck(bridged.domain == "SideStore.RemoteIdentity", "diagnostic domain")
            try fixtureCheck(bridged.code == expected, "diagnostic finite code")
        }
    }
    return passed
}

@main enum RemoteIdentityRegressionMain {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--cases-output" else {
                print("Required: --cases-output FILE"); exit(2)
            }
            let coreNames = try runCoreCases()
            let runtimeNames = try await runRuntimeCases()
            let names = coreNames + runtimeNames
            let report: [String: Any] = ["schema": "remote-identity-reuse-cases-v1", "status": "pass",
                "case_count": names.count, "cases": names, "fake_only": true,
                "native_provider_executed": false, "native_keychain_executed": false, "network_executed": false]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            for name in names { print("PASS " + name) }
            print("REMOTE_IDENTITY_REUSE_RUNTIME_PASS cases=\(names.count)")
        } catch {
            // Never print arbitrary underlying errors, Keychain queries or synthetic secret values.
            if case FixtureFailure.assertion(let label) = error { print("FAIL " + label) }
            else { print("FAIL unexpected_typed_error") }
            exit(1)
        }
    }
}
