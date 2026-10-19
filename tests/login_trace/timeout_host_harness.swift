func require(_ value: @autoclosure () -> Bool, _ label: String) {
    if !value() { fatalError(label) }
}
let id = "00000000-0000-0000-0000-000000000001"
let other = "00000000-0000-0000-0000-000000000002"
let trace = "v1;login_trace_v1;012345abcdef;1;0,2,3,2000,0,0,0"
let timeout = CombinedFailure(operation: "signIn", stage: .authentication, code: .timedOut, id: id,
    signingContext: [V3LoginDiagnosticSnapshot.contextKey: trace])
let reply: [String: Any] = ["state": "timedOut", "failure": timeout.wire]
let retained = V3AuthTimeoutDiagnosticRetentionPolicy.failure(reply: reply, expectedID: id)!
let rendered = V3AuthFailureDiagnosticsPolicy.render(retained, underlyingCode: 0, retryableValue: nil)
require(rendered.contains(trace), "actual host copy contains final timeout trace")
require(rendered.contains("timedOut"), "actual host copy contains typed timeout")
let previous: [String: Any] = ["kind": "accountRepairRequired", "retryable": false]
let selected = V3AuthTimeoutDiagnosticRetentionPolicy.selecting(state: "timedOut", timeout: retained, previous: previous)!
require(selected["code"] as? String == "timedOut", "timeout diagnostics supersede stale diagnostics only")
require(previous["kind"] as? String == "accountRepairRequired" && previous["retryable"] as? Bool == false,
    "existing action facts remain untouched")
for expected in [nil, other, "account@example.invalid"] as [String?] {
    require(V3AuthTimeoutDiagnosticRetentionPolicy.failure(reply: reply, expectedID: expected) == nil, "reject wrong session")
}
for state in ["working", "awaitingPrompt", "completed", "cancelled", "failed", "authenticatedProvisioningIncomplete"] {
    var changed = reply; changed["state"] = state
    require(V3AuthTimeoutDiagnosticRetentionPolicy.failure(reply: changed, expectedID: id) == nil, "clear non-timeout storage")
    let value = V3AuthTimeoutDiagnosticRetentionPolicy.selecting(state: state, timeout: retained, previous: previous)!
    require(NSDictionary(dictionary: value).isEqual(to: previous), "non-timeout rendering unchanged")
}
var noTrace = timeout.wire; noTrace["signingContext"] = [String: String]()
var oversized = timeout.wire; oversized["unknown"] = String(repeating: "SECRET", count: 1000)
var wrongID = timeout.wire; wrongID["correlationID"] = other
var invalid = timeout.wire; invalid["signingContext"] = [V3LoginDiagnosticSnapshot.contextKey: "SECRET"]
for failure in [noTrace, oversized, wrongID, invalid, ["raw": "TOKEN-CANARY"]] {
    require(V3AuthTimeoutDiagnosticRetentionPolicy.failure(reply: ["state": "timedOut", "failure": failure], expectedID: id) == nil,
        "reject missing/invalid/oversized payload")
}
require(V3AuthTimeoutDiagnosticRetentionPolicy.failure(reply: ["state": "timedOut"], expectedID: id) == nil,
    "new local timeout cannot reuse old trace")
require(V3AuthTimeoutDiagnosticRetentionPolicy.selecting(state: "timedOut", timeout: nil, previous: nil) == nil,
    "new attempt has no prior diagnostic")
require(!rendered.contains("SECRET") && !rendered.contains("TOKEN-CANARY"), "host copy redacts payloads")
var lifecycle: [String: Any]? = retained
if V3AuthTimeoutDiagnosticRetentionPolicy.shouldClearOnSessionChange(from: id, to: nil, state: "timedOut") {
    lifecycle = nil
}
let retired = V3AuthTimeoutDiagnosticRetentionPolicy.selecting(state: "timedOut", timeout: lifecycle, previous: nil)!
let retiredText = V3AuthFailureDiagnosticsPolicy.render(retired, underlyingCode: 0, retryableValue: nil)
require(retiredText.contains(trace), "normal terminal-session retirement retains copyable trace")
if V3AuthTimeoutDiagnosticRetentionPolicy.shouldClearOnSessionChange(from: nil, to: other, state: "working") {
    lifecycle = nil
}
require(lifecycle == nil, "new attempt cannot inherit retired session trace")
require(V3AuthTimeoutDiagnosticRetentionPolicy.shouldClearOnSessionChange(from: id, to: other, state: "timedOut"),
    "replacement while timedOut clears")
require(V3AuthTimeoutDiagnosticRetentionPolicy.shouldClearOnSessionChange(from: id, to: nil, state: "working"),
    "nonterminal ownership change clears")
require(!V3AuthTimeoutDiagnosticRetentionPolicy.shouldClearOnSessionChange(from: id, to: id, state: "timedOut"),
    "same session remains")
print("LOGIN_TIMEOUT_HOST_CONTRACT_PASS")
