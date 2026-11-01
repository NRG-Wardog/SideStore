// Actual production CMS C core + both Swift facade layers + strict decoder.
// Inputs are pinned public test data in a temporary directory, never emitted.
import Foundation
var cases: [String] = []
var outerContents: [Data] = []
var innerContents: [Data] = []
// Expected public certificate hashes are reviewed provenance, not runtime pins.
struct PublicSignerProvenance: Decodable { let leaf_sha256: String }
let signerProvenance = try JSONDecoder().decode([PublicSignerProvenance].self,
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
precondition(signerProvenance.count == 2)

let caseSuffixes = ["outer-role-authenticated", "inner-pinned-role-authenticated", "signer-diagnostic-facade", "complete-authority-bound", "outer-tamper-rejected", "inner-tamper-rejected", "inner-cannot-be-outer-role", "outer-cannot-be-inner-role", "cross-profile-binding-rejected"]
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
    beginCase("public-\(index)-signer-diagnostic-facade")
    // Actual production C -> Gateway -> Minimuxer facade, not a mock. This API
    // returns only finite evidence (no Data/profile-content member).
    let evidence: ProfileCMSSignerEvidence = ProfileCMSVerifier.diagnoseInnerSigner(nested)
    precondition(evidence.algorithmAndAttributes == .passed && evidence.pin == .passed)
    precondition(evidence.chain == .passed && evidence.temporal == .passed && evidence.signature == .passed)
    precondition(evidence.signerSHA256 == signerProvenance[index].leaf_sha256)
    precondition(evidence.signerSHA256?.count == 64)
    precondition(evidence.profileSubjectMarker && evidence.profileIssuerMarker && evidence.profileExtensionMarker)
    precondition(!evidence.appDeveloperMarker)
    // Exercise failed and unchecked enum mapping and fingerprint withholding
    // through both actual Swift wrappers, without logging any input or digest.
    var diagnosticTamper = nested; diagnosticTamper[diagnosticTamper.count-1] ^= 1
    let failed = ProfileCMSVerifier.diagnoseInnerSigner(diagnosticTamper)
    precondition(failed.chain == .passed && failed.temporal == .passed && failed.signature == .failed)
    precondition(failed.signerSHA256 == nil && !failed.profileSubjectMarker && !failed.profileIssuerMarker && !failed.profileExtensionMarker && !failed.appDeveloperMarker)
    let unchecked = ProfileCMSVerifier.diagnoseInnerSigner(Data())
    precondition(unchecked.algorithmAndAttributes == .unchecked && unchecked.pin == .unchecked && unchecked.chain == .unchecked && unchecked.temporal == .unchecked && unchecked.signature == .unchecked)
    precondition(unchecked.signerSHA256 == nil)
    cases.append("public-\(index)-signer-diagnostic-facade")
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
precondition(cases.count == 18 && Set(cases).count == 18)
let report: [String: Any] = ["schema":"preservation-der-public-v1", "status":"PASS", "cases":cases, "cms_verified":true, "device_executed":false]
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
