import Foundation

let now = Date(timeIntervalSince1970: 1000)
let der = Data([1, 2, 3])
func profile(_ uuid: Int, _ expiry: Double) -> [String: Any] {
    ["UUID": String(format: "00000000-0000-0000-0000-%012d", uuid),
     "CreationDate": Date(timeIntervalSince1970: 100),
     "ExpirationDate": Date(timeIntervalSince1970: expiry), "TimeToLive": 7,
     "TeamIdentifier": ["TEAM"], "ApplicationIdentifierPrefix": ["PREFIX"],
     "DeveloperCertificates": [der], "ProvisionedDevices": ["device"], "Platform": ["iOS"],
     "Entitlements": ["application-identifier": "PREFIX.example.app",
        "com.apple.developer.team-identifier": "TEAM",
        "keychain-access-groups": ["PREFIX.example.app", "PREFIX.shared"],
        "com.apple.security.application-groups": ["group.existing"], "get-task-allow": true]]
}
func binding(_ certExpiry: Double = 9000, reuse: Bool = true) -> PreservedProfilePolicy.Binding {
    .init(resignedBundleID: "example.app", applicationIdentifier: "PREFIX.example.app", teamID: "TEAM",
          historicalSignerDER: der, certificateExpiration: Date(timeIntervalSince1970: certExpiry), useMainProfile: reuse)
}
var passed: [String] = []
func accepted(_ label: String, old: [[String: Any]], new: [String: Any], b: PreservedProfilePolicy.Binding = binding()) {
    do { _ = try PreservedProfilePolicy.evaluate(binding: b, installed: old, candidate: new, now: now); passed.append(label) }
    catch { fatalError("\(label): unexpected \(error)") }
}
func rejected(_ label: String, _ expected: PreservedProfilePolicy.Failure, old: [[String: Any]], new: [String: Any], b: PreservedProfilePolicy.Binding = binding()) {
    do { _ = try PreservedProfilePolicy.evaluate(binding: b, installed: old, candidate: new, now: now); fatalError("\(label): accepted") }
    catch let e as PreservedProfilePolicy.Failure { precondition(e == expected, "\(label): \(e)"); passed.append(label) }
    catch { fatalError("\(label): unexpected \(error)") }
}
let old = profile(1, 2000), next = profile(2, 3000)
accepted("renew", old: [old], new: next)
accepted("identical duplicate", old: [old, old], new: next)
accepted("expired old allowed", old: [profile(1, 900)], new: next)
accepted("same authority duplicates", old: [old, profile(3, 2500)], new: next)
rejected("highest prior expiry", .noEffectiveExtension, old: [old, profile(3, 3500)], new: next)
rejected("cert caps improvement", .noEffectiveExtension, old: [old], new: next, b: binding(1500))
rejected("cert expired", .expiredCertificate, old: [old], new: next, b: binding(999))
rejected("not reuse", .missingHistoricalBinding, old: [old], new: next, b: binding(reuse: false))
rejected("missing inventory", .missingInstalledProfile, old: [], new: next)
rejected("same UUID overwrite", .duplicateUUIDConflict, old: [old], new: profile(1, 3000))
rejected("ambiguous UUID", .duplicateUUIDConflict, old: [old, profile(1, 2500)], new: next)
for key in ["ProvisionedDevices", "Platform", "ApplicationIdentifierPrefix", "DeveloperCertificates", "UnknownRestriction"] {
    var changed = next
    changed[key] = key == "DeveloperCertificates" ? [Data([4])] as Any : ["changed"] as Any
    rejected("changed \(key)", .changedAuthorization, old: [old], new: changed)
}
for key in ["keychain-access-groups", "com.apple.security.application-groups", "new-entitlement"] {
    var changed = next
    var ent = changed["Entitlements"] as! [String: Any]
    ent[key] = ["changed"]
    changed["Entitlements"] = ent
    rejected("entitlement \(key)", .changedAuthorization, old: [old], new: changed)
}
var reordered = next
var ent = reordered["Entitlements"] as! [String: Any]
ent["keychain-access-groups"] = ["PREFIX.shared", "PREFIX.example.app"]
reordered["Entitlements"] = ent
rejected("default keychain group", .changedAuthorization, old: [old], new: reordered)
var wrongBool = next
ent = wrongBool["Entitlements"] as! [String: Any]; ent["get-task-allow"] = 1
wrongBool["Entitlements"] = ent
rejected("bool not integer", .changedAuthorization, old: [old], new: wrongBool)
var conflict = profile(3, 2500)
ent = conflict["Entitlements"] as! [String: Any]; ent["new-entitlement"] = true
conflict["Entitlements"] = ent
rejected("same identity authority conflict", .entitlementsDiffer, old: [old, conflict], new: next)
var malformed = next; malformed.removeValue(forKey: "DeveloperCertificates")
rejected("partial profile projection", .malformedProfile, old: [old], new: malformed)
func preflight(_ profiles: [[String: Any]]) throws -> PreservedProfilePolicy.Evidence {
    try PreservedProfilePolicy.selectSnapshot(resignedBundleID: "example.app", teamID: "TEAM",
        historicalSignerDER: der, certificateExpiration: Date(timeIntervalSince1970: 9000),
        useMainProfile: true, installed: profiles, now: now)
}
let baseline = try preflight([old])
precondition(baseline.binding.applicationIdentifier == "PREFIX.example.app"); passed.append("preflight-selected-identity")
let duplicateBaseline = try preflight([old, old])
precondition(baseline == duplicateBaseline); passed.append("preflight-identical-duplicate")
var otherPrefix = profile(3, 2000)
ent = otherPrefix["Entitlements"] as! [String: Any]
ent["application-identifier"] = "OTHER.example.app"
otherPrefix["Entitlements"] = ent; otherPrefix["ApplicationIdentifierPrefix"] = ["OTHER"]
for (label, bad) in [("preflight-alternate-prefix", [old, otherPrefix]), ("preflight-conflicting-authority", [conflict, old]), ("preflight-malformed", [malformed])] {
    do { _ = try preflight(bad); fatalError("invalid preflight accepted") }
    catch is PreservedProfilePolicy.Failure { passed.append(label) }
}
var inconsistentPrefix = old; inconsistentPrefix["ApplicationIdentifierPrefix"] = ["WRONG"]
do { _ = try preflight([inconsistentPrefix]); fatalError("wrong prefix accepted") }
catch is PreservedProfilePolicy.Failure { passed.append("preflight-inconsistent-prefix") }
let changedInventory = try preflight([old, profile(3, 2500)])
precondition(baseline != changedInventory); passed.append("inventory-change-detected")

var unrelated = profile(8, 2500)
ent = unrelated["Entitlements"] as! [String: Any]
ent["application-identifier"] = "PREFIX.unrelated.app"
unrelated["Entitlements"] = ent
let unrelatedDelta = try preflight([old, unrelated])
precondition(baseline.hasSameTarget(as: unrelatedDelta)); passed.append("unrelated-inventory-preserved-target")
precondition(!baseline.hasSameTarget(as: changedInventory)); passed.append("changed-inventory-different-target")
// A new unrelated UUID collision must still be rejected using FRESH inventory.
var collided = unrelated; collided["UUID"] = next["UUID"]
let freshCollision = try preflight([old, collided])
do { _ = try PreservedProfilePolicy.validate(candidate: next, baseline: freshCollision, now: now); fatalError("fresh collision accepted") }
catch let error as PreservedProfilePolicy.Failure { precondition(error == .duplicateUUIDConflict); passed.append("fresh-uuid-collision") }
do {
    _ = try PreservedProfilePolicy.snapshot(binding: baseline.binding, installed: [old, otherPrefix], now: now)
    fatalError("fresh alternate prefix accepted")
} catch let error as PreservedProfilePolicy.Failure {
    precondition(error == .alternateIdentity); passed.append("fresh-alternate-prefix-conflict")
}

// Every refinement remains rejection-only and is invariant to inventory order.
func diagnostic(_ label: String, _ expected: PreservedProfilePolicy.Failure, _ inventory: [[String: Any]]) {
    for items in [inventory, Array(inventory.reversed())] {
        do { _ = try preflight(items); fatalError("diagnostic accepted") }
        catch let error as PreservedProfilePolicy.Failure { precondition(error == expected, "\(label): \(error)") }
        catch { fatalError("unexpected diagnostic error") }
    }
    precondition(expected.preservationConflict == expected.rawValue)
    passed.append(label)
}
diagnostic("detail-multiple-identities", .multipleIdentities, [old, otherPrefix])
var teamMismatch = profile(4, 2500)
var teamEnt = teamMismatch["Entitlements"] as! [String: Any]
teamEnt["com.apple.developer.team-identifier"] = "OTHER"
teamMismatch["Entitlements"] = teamEnt; teamMismatch["TeamIdentifier"] = ["OTHER"]
diagnostic("detail-team-mismatch", .teamMismatch, [old, teamMismatch])
diagnostic("detail-prefix-mismatch", .prefixMismatch, [old, inconsistentPrefix.merging(["UUID": profile(4,2500)["UUID"]!]) { _, new in new }])
var signerMissing = profile(4, 2500); signerMissing["DeveloperCertificates"] = [Data([4])]
diagnostic("detail-signer-missing", .signerMissing, [old, signerMissing])
diagnostic("detail-entitlements-differ", .entitlementsDiffer, [old, conflict])
let fieldDiagnostics: [(String, Any, PreservedProfilePolicy.Failure, String)] = [
    ("DeveloperCertificates", [der, Data([4])], .certificatesDiffer, "detail-certificates-differ"),
    ("ProvisionedDevices", ["other"], .devicesDiffer, "detail-devices-differ"),
    ("Platform", ["other"], .platformsDiffer, "detail-platforms-differ"),
    ("DER-Encoded-Profile", Data([4]), .embeddedDERDiffer, "detail-embedded-der-differ"),
    ("Name", "other", .displayMetadataDiffer, "detail-display-metadata-differ"),
    ("UnknownRestriction", true, .otherAuthorityDiffer, "detail-other-authority-differ")
]
for (key, value, expected, label) in fieldDiagnostics {
    var changed = profile(4, 2500); changed[key] = value
    diagnostic(label, expected, [old, changed])
}
var multipleDifferences = conflict
multipleDifferences["DER-Encoded-Profile"] = Data([4]); multipleDifferences["Name"] = "other"
diagnostic("detail-fixed-precedence", .entitlementsDiffer, [old, multipleDifferences])
// A stale expired profile still participates: diagnosis must not relax admission.
var expiredConflict = conflict; expiredConflict["ExpirationDate"] = Date(timeIntervalSince1970: 900)
diagnostic("detail-expired-conflict-retained", .entitlementsDiffer, [old, expiredConflict])

// Identity regression: a different valid bundle can end in our complete ID.
var suffixNeighbor = profile(20, 2500)
var suffixEntitlements = suffixNeighbor["Entitlements"] as! [String: Any]
suffixEntitlements["application-identifier"] = "PREFIX.other.example.app"
suffixNeighbor["Entitlements"] = suffixEntitlements
let priorSuffixIdentities = Set([old, suffixNeighbor].compactMap {
    ($0["Entitlements"] as? [String: Any])?["application-identifier"] as? String
}.filter { !$0.contains("*") && $0.hasSuffix(".example.app") && $0.count > "example.app".count + 1 })
precondition(priorSuffixIdentities.count == 2) // Exact prior guard rejected this inventory.
for inventory in [[old, suffixNeighbor], [suffixNeighbor, old]] {
    let selected = try preflight(inventory)
    precondition(selected.binding == baseline.binding && selected.priorUUIDs == baseline.priorUUIDs)
}
passed.append("identity-valid-suffix-neighbor-not-target")
let freshSuffix = try PreservedProfilePolicy.snapshot(binding: baseline.binding, installed: [old, suffixNeighbor], now: now)
precondition(baseline.hasSameTarget(as: freshSuffix))
_ = try PreservedProfilePolicy.validate(candidate: next, baseline: freshSuffix, now: now)
passed.append("identity-fresh-suffix-neighbor-no-drift")
do { _ = try preflight([suffixNeighbor]); fatalError("suffix-only inventory selected") }
catch let error as PreservedProfilePolicy.Failure {
    precondition(error == .missingInstalledProfile); passed.append("identity-suffix-only-missing-target")
}
// Legacy prefix remains independent of the team; no TeamID synthesis.
precondition(baseline.binding.applicationIdentifier == "PREFIX.example.app" && baseline.binding.teamID == "TEAM")
passed.append("identity-legacy-prefix-not-team-preserved")
for (label, prefixes) in [("identity-dotted-prefix-rejected", ["PREFIX.other"]),
                          ("identity-ambiguous-prefix-rejected", ["PREFIX", "OTHER"])] {
    var malformedIdentity = suffixNeighbor
    malformedIdentity["ApplicationIdentifierPrefix"] = prefixes
    do { _ = try preflight([malformedIdentity]); fatalError("malformed prefix selected") }
    catch let error as PreservedProfilePolicy.Failure {
        precondition(error == .prefixMismatch); passed.append(label)
    }
}
var wildcardIdentity = suffixNeighbor
suffixEntitlements["application-identifier"] = "PREFIX.*.example.app"
wildcardIdentity["Entitlements"] = suffixEntitlements
let wildcardSnapshot = try preflight([old, wildcardIdentity])
precondition(baseline.hasSameTarget(as: wildcardSnapshot)); passed.append("identity-wildcard-not-selected")
do { _ = try preflight([old, suffixNeighbor, otherPrefix]); fatalError("real alternate prefix selected") }
catch let error as PreservedProfilePolicy.Failure {
    precondition(error == .multipleIdentities); passed.append("identity-real-alternate-prefix-still-conflicts")
}

precondition(passed.count == 55 && Set(passed).count == 55)
print(String(data: try JSONSerialization.data(withJSONObject: ["schema":"preservation-refresh-policy-v1", "status":"PASS", "cases":passed, "device_executed":false], options:[.sortedKeys]), encoding:.utf8)!)
