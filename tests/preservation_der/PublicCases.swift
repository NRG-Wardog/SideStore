// Actual production CMS C core + both Swift facade layers + strict decoder.
// Inputs are pinned public test data in a temporary directory, never emitted.
import Foundation
var cases: [String] = []
var outerContents: [Data] = []
var innerContents: [Data] = []
let caseSuffixes = ["outer-role-authenticated", "inner-pinned-role-authenticated", "complete-authority-bound", "outer-tamper-rejected", "inner-tamper-rejected", "inner-cannot-be-outer-role", "outer-cannot-be-inner-role", "cross-profile-binding-rejected"]
let allowedCaseNames = Set((0..<2).flatMap { index in caseSuffixes.map { "public-\(index)-\($0)" } })
func beginCase(_ name: String) {
    precondition(allowedCaseNames.contains(name))
    FileHandle.standardError.write(Data(("V3_PUBLIC_CASE_BEGIN " + name + "\n").utf8))
}
func rejected(_ name: String, _ operation: () throws -> Void) {
    beginCase(name)
    do { try operation(); fatalError("unexpected acceptance: \(name)") }
    catch { cases.append(name) }
}
for index in 0..<2 {
    beginCase("public-\(index)-outer-role-authenticated")
    let cms = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("profile-\(index).cms"))
    let outer = try ProfileCMSVerifier.authenticateOuter(cms)
    cases.append("public-\(index)-outer-role-authenticated")
    beginCase("public-\(index)-inner-pinned-role-authenticated")
    let dictionary = try PreservedProfileDecoder.decodeOuter(verifiedOuterXML: outer)
    guard let nested = dictionary["DER-Encoded-Profile"] as? Data, !nested.isEmpty else { fatalError("public fixture schema") }
    let inner = try ProfileCMSVerifier.authenticateInner(nested)
    cases.append("public-\(index)-inner-pinned-role-authenticated")
    beginCase("public-\(index)-complete-authority-bound")
    let result = try PreservedProfileDecoder.decode(verifiedOuterXML: outer, verifiedInnerDER: inner)
    precondition(result.rawInner == inner && !result.normalizedInnerAuthority.isEmpty)
    cases.append("public-\(index)-complete-authority-bound")
    outerContents.append(outer); innerContents.append(inner)
    var corruptOuter = cms; corruptOuter[corruptOuter.count-1] ^= 1
    rejected("public-\(index)-outer-tamper-rejected") { _ = try ProfileCMSVerifier.authenticateOuter(corruptOuter) }
    var corruptInner = nested; corruptInner[corruptInner.count-1] ^= 1
    rejected("public-\(index)-inner-tamper-rejected") { _ = try ProfileCMSVerifier.authenticateInner(corruptInner) }
    rejected("public-\(index)-inner-cannot-be-outer-role") { _ = try ProfileCMSVerifier.authenticateOuter(nested) }
    rejected("public-\(index)-outer-cannot-be-inner-role") { _ = try ProfileCMSVerifier.authenticateInner(cms) }
}
for index in 0..<2 {
    rejected("public-\(index)-cross-profile-binding-rejected") {
        _ = try PreservedProfileDecoder.decode(verifiedOuterXML: outerContents[index], verifiedInnerDER: innerContents[1-index])
    }
}
precondition(cases.count == 16 && Set(cases).count == 16)
let report: [String: Any] = ["schema":"preservation-der-public-v1", "status":"PASS", "cases":cases, "cms_verified":true, "device_executed":false]
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
