let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let failure = CombinedFailure.fromEncodedString(text, expectedID: "00000000-0000-0000-0000-000000000001")!
var wire = failure.wire; wire["kind"] = "anisette"
let rendered = V3AuthFailureDiagnosticsPolicy.render(wire, underlyingCode: -2, retryableValue: nil)
for (key, value) in ["native_init_kind": "dt_init", "native_init_reason": "engine_error",
    "native_init_engine": "13", "native_init_library": "0", "native_init_initializer": "0"] {
    precondition(failure.signingContext[key] == value)
    precondition(failure.technicalDetails.contains("\(key)=\(value)"))
    precondition(rendered.contains("\(key)=\(value)"))
}
precondition(rendered.contains("native_phase=setupConstructors") && rendered.contains("native_subcode=unknown"))
precondition(!rendered.contains("Library constructor") && !rendered.contains("SECRET"))
print("INITIALIZER_HOST_ROUNDTRIP_PASS")

// A separately compiled importing host decodes the service-produced fault wire.
let faultText = try String(contentsOfFile: CommandLine.arguments[1] + ".fault", encoding: .utf8)
let faultFailure = CombinedFailure.fromEncodedString(faultText, expectedID: "00000000-0000-0000-0000-000000000001")!
var faultEnvelope = faultFailure.wire; faultEnvelope["kind"] = "anisette"
let faultRendered = V3AuthFailureDiagnosticsPolicy.render(faultEnvelope, underlyingCode: -2, retryableValue: nil)
let copied = V3DiagnosticCopy.details(visibleMessage: "Synthetic sign-in failure\nError ID: SS-AUTH-D024", technical: faultRendered)
precondition(copied.contains("visible_error_id=SS-AUTH-D024"))
precondition(copied.hasSuffix(faultRendered))
for (key, value) in ["native_fault_access": "1", "native_fault_width": "8", "native_fault_region": "2",
    "native_fault_pc_library": "0", "native_fault_pc_offset": "100", "native_fault_guard": "1",
    "native_fault_sha0": "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    "native_fault_sha1": "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0"] {
    precondition(faultFailure.technicalDetails.contains("\(key)=\(value)"))
    precondition(faultRendered.contains("\(key)=\(value)"))
    precondition(copied.contains("\(key)=\(value)"))
}
precondition(faultFailure.signingContext["native_init_engine"] == "13")
precondition(!faultRendered.contains("p0_fault_diag1") && !faultRendered.contains("SECRET"))
for raw in ["SECRET", "v1;p0_fault_diag1;0;8;2;0;100;1;-;-"] {
    var forged = faultFailure.signingContext; forged[V3ConstructorFaultDiagnostic.contextKey] = raw
    var invalid = faultFailure.wire; invalid["signingContext"] = forged
    precondition(CombinedFailure.decode(invalid, expectedID: "00000000-0000-0000-0000-000000000001") == nil)
    invalid["kind"] = "anisette"
    let rejected = V3AuthFailureDiagnosticsPolicy.render(invalid, underlyingCode: -2, retryableValue: nil)
    precondition(!rejected.contains("native_fault_") && !rejected.contains("SECRET"))
}
print("CONSTRUCTOR_FAULT_HOST_ROUNDTRIP_PASS")
