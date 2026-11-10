let causeKey = V3ProvisioningCauseDiagnostic.contextKey
let stateKey = V3AuthenticationDiagnostics.stateKey
let cause = "pc1|listDevices|0|0|0|listDevices,portal,invalidDeviceID,-,-,-,-,unobserved,unavailable,unavailable,-,-,0"
precondition(V3ProvisioningCauseDiagnostic.validated(cause) != nil)
let primary = [causeKey: cause, "native_code": "-1", "native_phase": "initialize", "native_subcode": "unknown"]
func bounded(_ context: [String: String]) -> [String: Any] {
    V3AuthenticationDiagnostics.boundingWire(["code": "authenticationFailed", "signingContext": context])
}
func fields(_ wire: [String: Any]) -> [String: String] { wire["signingContext"] as! [String: String] }
func checkPrimary(_ context: [String: String]) {
    for (key, value) in primary { precondition(context[key] == value, "primary evidence lost") }
}
// 1. Bookkeeping only: every input byte survives and state is recorded.
let lossless = bounded(primary)
var expected = primary; expected[stateKey] = "recorded"
precondition(fields(lossless) == expected, "lossless state must be recorded")
precondition(V3AuthenticationDiagnostics.fits(lossless))
// 2. Bounding twice must not manufacture trimming.
precondition(fields(V3AuthenticationDiagnostics.boundingWire(lossless)) == expected)
// 3. A prior truthful state is not reset.
for state in ["recorded", "trimmed", "rejected", "notRecorded"] {
    var context = primary; context[stateKey] = state
    precondition(fields(bounded(context))[stateKey] == state)
}
// 4. Real count pressure removes ancillary values, not the primary tuple.
var crowded = primary
for index in 0..<15 { crowded["reserved_\(index)"] = "x" }
crowded["capability_names"] = "optional"
let countBounded = fields(bounded(crowded))
precondition(countBounded.count <= 20 && countBounded["capability_names"] == nil)
precondition(countBounded[stateKey] == "trimmed"); checkPrimary(countBounded)
// 5. Real wire pressure remains bounded in BOTH binary plist and JSON.
var large = primary; large["capability_names"] = String(repeating: "x", count: 5000)
let byteBounded = bounded(large)
precondition(V3AuthenticationDiagnostics.fits(byteBounded))
precondition(fields(byteBounded)["capability_names"] == nil)
precondition(fields(byteBounded)[stateKey] == "trimmed"); checkPrimary(fields(byteBounded))
// 6. Malformed optional observations are rejected, never echoed.
for key in [V3AuthenticationRequestSnapshot.contextKey, V3AuthenticationHeaderProvenance.contextKey,
            V3AuthenticationProviderObservation.contextKey] {
    var invalid = primary; invalid[key] = "PRIVATE_SENTINEL"
    let output = fields(bounded(invalid))
    precondition(output[key] == nil && output[stateKey] == "rejected")
    precondition(!output.values.contains("PRIVATE_SENTINEL")); checkPrimary(output)
}
// 7. Rejected primary diagnostics use the finite rejection value.
let invalidCause = fields(bounded([causeKey: "PRIVATE_SENTINEL"]))
precondition(invalidCause[causeKey] == V3ProvisioningCauseDiagnostic.rejected)
precondition(invalidCause[stateKey] == "rejected")
// 8. Absent diagnostics do not gain fabricated observation state.
let plain = ["native_code": "-1"]
precondition(fields(bounded(plain)) == plain)
print("PASS diagnostic bounds: 8 cases")
