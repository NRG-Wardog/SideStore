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
