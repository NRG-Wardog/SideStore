func require(_ value: @autoclosure () -> Bool, _ label: String) {
    if !value() { fatalError(label) }
}
let prefix = "v1;login_trace_v1;012345abcdef;0;"
let row = "54,2,0,100,20,2,-45061"
let valid = prefix + row
require(V3LoginDiagnosticSnapshot(encoded: valid)?.encoded == valid, "canonical native row")
require(V3LoginDiagnosticSnapshot(encoded: prefix) != nil, "empty trace")
for invalid in [
    prefix + "57,2,0,100,20,2,-45061", prefix + "-1,2,0,100,20,2,-45061",
    prefix + "54,4,0,100,20,2,-45061", prefix + "54,2,12,100,20,2,-45061",
    prefix + "54,2,0,86400001,20,2,-45061", prefix + "54,2,0,100,86400001,2,-45061",
    prefix + "54,2,0,100,20,9,-45061", prefix + "54,2,0,100,20,2,-2147483649",
    prefix + "54,2,0,100,20,8,1234", prefix + "54,2,0,100,20,4,7",
    prefix + "54,2,0,100,20,5,1000000", prefix + "054,2,0,100,20,2,-45061",
    prefix + "+54,2,0,100,20,2,-45061", prefix + "54, 2,0,100,20,2,-45061",
    prefix + "54,2,0,100,20,2,-45061,SECRET", prefix + row + ";",
    valid.replacingOccurrences(of: "012345abcdef", with: "user@example.com"),
    valid.replacingOccurrences(of: "012345abcdef", with: "012345ABCDEF"),
    valid.replacingOccurrences(of: "login_trace_v1", with: "SECRET"),
    prefix + String(repeating: "SECRET", count: 500)
] { require(V3LoginDiagnosticSnapshot(encoded: invalid) == nil, "reject malformed metadata") }
let baseline: [String: Any] = ["version": 1, "operation": "signIn", "stage": "authentication", "code": "failed",
    "correlationID": "6DAA781A-5413-4EC2-9E93-1BA2E3C06928", "underlyingDomain": "redacted", "underlyingCode": -2,
    "signingContext": ["typed_error": "anisetteKitADIError", "native_phase": "setupConstructors"]]
let wire = V3LoginDiagnosticSnapshot.attaching(valid, to: baseline)
let fields = wire["signingContext"] as! [String: String]
require(fields["typed_error"] == "anisetteKitADIError", "preserve causal evidence")
require(fields[V3LoginDiagnosticSnapshot.contextKey] == valid, "attach trace")
require(!V3LoginDiagnosticSnapshot(encoded: valid)!.technicalDetails.contains("SECRET"), "no provider payload")
var full = baseline
var wide = fields
wide.removeValue(forKey: V3LoginDiagnosticSnapshot.contextKey)
wide["padding"] = String(repeating: "x", count: 2600)
full["signingContext"] = wide
let long = prefix + Array(repeating: row, count: 60).joined(separator: ";")
require(long.utf8.count <= 2048, "fixture under observer cap")
let bounded = V3LoginDiagnosticSnapshot.attaching(long, to: full)
let data = try PropertyListSerialization.data(fromPropertyList: bounded, format: .binary, options: 0)
require(data.count <= 4096, "bounded failure envelope")
let boundedFields = bounded["signingContext"] as! [String: String]
require(boundedFields["padding"] == wide["padding"], "never drop original evidence")
require(boundedFields[V3LoginDiagnosticSnapshot.contextKey]!.hasPrefix("v1;login_trace_v1;012345abcdef;1;"), "explicit loss")
require(V3LoginDiagnosticSnapshot(encoded: boundedFields[V3LoginDiagnosticSnapshot.contextKey]!) != nil, "trimmed output canonical")
var twenty = baseline
twenty["signingContext"] = Dictionary(uniqueKeysWithValues: (0..<20).map { ("key\($0)", "safe") })
let noRoom = V3LoginDiagnosticSnapshot.attaching(valid, to: twenty)
require((noRoom["signingContext"] as! [String: String])[V3LoginDiagnosticSnapshot.contextKey] == nil, "preserve 20-field cap")
let invalid = V3LoginDiagnosticSnapshot.attaching("SECRET", to: baseline)
require((invalid["signingContext"] as! [String: String])[V3LoginDiagnosticSnapshot.contextKey] == nil, "invalid optional input ignored")
// Session timeout gets an existing-format failure envelope without modifying
// any state/authentication/retry decision or replacing a prior portal error.
for authenticated in [false, true] {
    for resumable in [false, true] {
        let original = V3AuthSessionExpiryPolicy.response(authenticated: authenticated, resumable: resumable)
        let stage = authenticated ? "provisioning" : "authentication"
        var timeoutFailure = baseline
        timeoutFailure["stage"] = stage; timeoutFailure["code"] = "timedOut"
        let enriched = V3AuthTimeoutDiagnosticPolicy.attaching(failure: timeoutFailure,
            technicalDetails: "fixed-details", to: original)
        for (key, value) in original {
            require(NSDictionary(dictionary: [key: value]).isEqual(to: [key: enriched[key]!]), "preserve terminal fields")
        }
        require(enriched["stage"] as? String == stage, "correct timeout stage")
        require(enriched["code"] as? String == "timedOut", "typed timeout")
        var rejected = original; rejected["failure"] = baseline; rejected["resumable"] = false
        let preserved = V3AuthTimeoutDiagnosticPolicy.attaching(failure: timeoutFailure,
            technicalDetails: "fixed-details", to: rejected)
        require(NSDictionary(dictionary: preserved).isEqual(to: rejected), "preserve prior portal failure")
        let finalRow = "0,2,3,101,0,0,0"
        let capped = prefix + Array(repeating: row, count: 60).joined(separator: ";") + ";" + finalRow
        let exported = V3LoginDiagnosticSnapshot.attaching(capped, to: timeoutFailure)
        let snapshot = (exported["signingContext"] as! [String: String])[V3LoginDiagnosticSnapshot.contextKey]!
        require(snapshot.hasSuffix(finalRow), "timeout final event survives bounded export")
    }
}
for state in ["completed", "cancelled", "awaitingPrompt", "failed"] {
    let original: [String: Any] = ["state": state, "authenticated": false]
    let unchanged = V3AuthTimeoutDiagnosticPolicy.attaching(failure: baseline, technicalDetails: "fixed-details", to: original)
    require(NSDictionary(dictionary: unchanged).isEqual(to: original), "non-timeout response unchanged")
}
print("LOGIN_TRACE_HOST_CONTRACT_PASS")
