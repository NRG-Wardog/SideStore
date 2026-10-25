import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
let order = ["remoteMac", "onDevice", "remoteServer"]
let plan = V3DiagnosticProviderPlan(order)!
expect(plan.encoded == order.joined(separator: ","), "preserve user order")
for bad in [[], ["remoteMac", "remoteMac"], ["unknown"], [" remoteMac"], ["remoteMac", "onDevice", "remoteServer", "remoteMac"]] {
    expect(V3DiagnosticProviderPlan(bad) == nil, "reject malformed plan")
}
expect(V3DiagnosticProviderPlan.offered(kind: "credentials", capability: V3DiagnosticProviderPlan.capability, providers: order) == plan, "exact capability")
for kind in ["twoFactor", "team", "credentials "] {
    expect(V3DiagnosticProviderPlan.offered(kind: kind, capability: V3DiagnosticProviderPlan.capability, providers: order) == nil, "credentials only")
}
for capability in [nil, "submit-v2", "isolated-signin-sequence-v2"] {
    expect(V3DiagnosticProviderPlan.offered(kind: "credentials", capability: capability, providers: order) == nil, "no implicit capability")
}
expect(plan.selecting(["remoteServer", "remoteMac"])?.encoded == "remoteServer,remoteMac", "subset order")
expect(V3DiagnosticProviderPlan(["remoteMac"])!.selecting(["onDevice"]) == nil, "unoffered provider")

var first = V3DiagnosticProviderSequence(plan: plan)
let firstAttempt = first.start(now: 0)!
expect(first.start(now: 1) == nil, "duplicate submit blocked")
first.succeeded(firstAttempt)
expect(first.state == .succeeded(0), "first provider success")
expect(first.attempt == nil && first.results.count == 1, "no credential/result payload")
expect(first.continueAfterBackoff(now: 100) == nil, "success stops sequence")
first.cancel()
expect(first.state == .succeeded(0), "terminal immutable")

var later = V3DiagnosticProviderSequence(plan: plan)
let old = later.start(now: 0)!
later.failed(old, reason: .providerUnavailable)
expect(later.state == .stopping(0), "must stop previous attempt")
expect(later.continueAfterBackoff(now: 100) == nil, "no overlapping attempts")
later.previousAttemptStopped(old, isolated: true, credentialsCommitted: false, now: 1)
expect(later.continueAfterBackoff(now: 2) == nil, "backoff enforced")
let next = later.continueAfterBackoff(now: 3)!
expect(next.provider == .onDevice && next.generation != old.generation, "ordered fresh attempt")
later.succeeded(old)
expect(later.state == .attempting(1), "stale completion ignored")
later.succeeded(next)
expect(later.state == .succeeded(1), "later success")

for failure in [V3DiagnosticProviderSequence.Failure.invalidCredentials, .accountRestricted, .rateLimited, .invalidCode, .identityChanged, .credentialStorage, .unknown] {
    var sequence = V3DiagnosticProviderSequence(plan: plan)
    let current = sequence.start(now: 0)!
    sequence.failed(current, reason: failure)
    expect(sequence.state == .stopped(failure), "non-retryable account failure")
    expect(sequence.continueAfterBackoff(now: 100) == nil, "no account retry")
}
for failure in [V3DiagnosticProviderSequence.Failure.providerUnavailable, .transientNetwork, .timedOut] {
    var sequence = V3DiagnosticProviderSequence(plan: plan)
    let current = sequence.start(now: 0)!
    sequence.needsUser(current)
    expect(sequence.checkTimeout(now: 1000) == nil, "2FA input suspends attempt timer")
    sequence.resumedByUser(current, now: 1000)
    sequence.failed(current, reason: failure)
    expect(sequence.state == .stopped(failure), "challenge latch prevents repeated challenges")
}
for isolation in [false, true] {
    var sequence = V3DiagnosticProviderSequence(plan: plan)
    let current = sequence.start(now: 0)!
    expect(sequence.checkTimeout(now: 59) == nil, "before deadline")
    expect(sequence.checkTimeout(now: 60) == current, "timeout requests cancellation")
    sequence.previousAttemptStopped(current, isolated: isolation, credentialsCommitted: true, now: 61)
    expect(sequence.state == .stopped(.identityChanged), "never retry credential commit")
}
var uncertain = V3DiagnosticProviderSequence(plan: plan)
let uncertainAttempt = uncertain.start(now: 0)!
uncertain.failed(uncertainAttempt, reason: .transientNetwork)
uncertain.previousAttemptStopped(uncertainAttempt, isolated: false, credentialsCommitted: false, now: 1)
expect(uncertain.state == .stopped(.identityChanged), "cache isolation required")

var exhausted = V3DiagnosticProviderSequence(plan: plan)
var attempt = exhausted.start(now: 0)!
for index in 0..<3 {
    exhausted.failed(attempt, reason: .transientNetwork)
    exhausted.previousAttemptStopped(attempt, isolated: true, credentialsCommitted: false, now: Double(index * 10))
    if index < 2 { attempt = exhausted.continueAfterBackoff(now: Double((index + 1) * 10))! }
}
expect(exhausted.state == .exhausted && exhausted.results.count == 3, "bounded exhaustion")
expect(exhausted.start(now: 100) == nil, "no restart loop")
var cancelled = V3DiagnosticProviderSequence(plan: plan)
let cancelledAttempt = cancelled.start(now: 0)!
cancelled.cancel()
cancelled.succeeded(cancelledAttempt)
cancelled.previousAttemptStopped(cancelledAttempt, isolated: true, credentialsCommitted: false, now: 1)
expect(cancelled.state == .cancelled, "late callback cannot revive cancellation")
var badClock = V3DiagnosticProviderSequence(plan: plan)
expect(badClock.start(now: .nan) == nil, "invalid clock refused")
expect(badClock.start(now: .infinity) == nil, "infinite clock refused")
print("Provider sequence: \(checks) checks passed")
