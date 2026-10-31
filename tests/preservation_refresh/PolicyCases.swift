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
rejected("same identity authority conflict", .conflictingInstalledAuthority, old: [old, conflict], new: next)
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
    precondition(error == .conflictingInstalledAuthority); passed.append("fresh-alternate-prefix-conflict")
}

precondition(passed.count == 34 && Set(passed).count == 34)
print(String(data: try JSONSerialization.data(withJSONObject: ["schema":"preservation-refresh-policy-v1", "status":"PASS", "cases":passed, "device_executed":false], options:[.sortedKeys]), encoding:.utf8)!)
