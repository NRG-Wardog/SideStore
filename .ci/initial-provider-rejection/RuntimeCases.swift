func initialProviderRetryConsumerCases() async throws {
    let status: [String: any Sendable] = ["ec": -80045, "hsc": 500]
    let response: [String: any Sendable] = ["Status": status]
    let session = FakeSession([Step(body: try plist(["Response": response]))])
    let ownedContext = FixtureOwnedODAContext()
    var rejection: Error?
    do {
        _ = try await OwnedODAAuthentication.$current.withValue(ownedContext) {
            try await v3AuthenticationPhase(.appleAuthentication) {
                try await DeveloperPortal(session: session).authenticate(appleID: "test@example.invalid", password: "synthetic", anisetteData: fixedAnisette(), xcodeVersion: "synthetic")
            }
        }
    } catch { rejection = error }
    guard let rejection else { throw FixtureFailure.assertion("real producer did not reject") }
    try expect(rejection is V3AuthenticationPhaseError, "actual auth-phase wrapper")
    let consumer = RetryConsumer(ownedContext: ownedContext)
    try expect(RetryConsumer(ownedContext: FixtureOwnedODAContext()).classify(rejection) == .unknown, "genuine marker from context A rejected for context B")
    try expect(RetryConsumer(ownedContext: nil).classify(rejection) == .unknown, "missing originating context fails closed")
    try expect(consumer.classify(rejection) == .providerRejectedInit, "actual consumer accepts actual producer through wrapper")
    let wrapped = V3AccountOperationError(underlying: V3AnisetteAttemptError(underlying: V3ProvisioningCauseError(underlying: rejection, provisioningCause: "synthetic"), context: .init()))
    try expect(consumer.classify(wrapped) == .providerRejectedInit, "bounded own wrappers preserve evidence")
    for provider in [V3DiagnosticProvider.remoteMac, .remoteServer] {
        try expect(consumer.classify(rejection, provider: provider) == .unknown, "marker not reusable on other provider")
    }
    let uncertainErrors: [Error] = [ServerError.underlyingError(code: -80045, message: "synthetic"),
                         NSError(domain: "OwnedODAInitialProviderRejection", code: -80045),
                         NSError(domain: "synthetic", code: -80045, userInfo: [NSUnderlyingErrorKey: rejection]),
                         V3DiagnosticAttemptTimeout(), URLError(.timedOut), URLError(.networkConnectionLost)]
    for error in uncertainErrors {
        try expect(consumer.classify(error) == .unknown, "generic/ambiguous error cannot grant retry")
    }
    let plan = V3DiagnosticProviderPlan(["onDevice", "remoteMac", "remoteServer"])!
    var sequence = V3DiagnosticProviderSequence(plan: plan)
    let first = sequence.start(now: 0)!
    sequence.failed(first, reason: consumer.classify(rejection))
    try expect(sequence.state == .stopping(0), "must drain before next")
    try expect(sequence.continueAfterBackoff(now: 100) == nil, "time alone is not cleanup")
    sequence.previousAttemptStopped(first, isolated: true, credentialsCommitted: false, now: 1)
    try expect(sequence.continueAfterBackoff(now: 2) == nil, "backoff enforced")
    let next = sequence.continueAfterBackoff(now: 3)!
    try expect(next.provider == .remoteMac && next.generation != first.generation, "explicit ordered fresh attempt")
    sequence.failed(first, reason: .providerRejectedInit)
    try expect(sequence.state == .attempting(1), "stale callback ignored")
    sequence.succeeded(next)
    try expect(sequence.state == .succeeded(1) && sequence.results.count == 2, "working Remote Mac terminates chain")
    for (isolated, committed) in [(false, false), (true, true)] {
        var s = V3DiagnosticProviderSequence(plan: plan); let a = s.start(now: 0)!
        s.failed(a, reason: .providerRejectedInit)
        s.previousAttemptStopped(a, isolated: isolated, credentialsCommitted: committed, now: 1)
        try expect(s.state == .stopped(.identityChanged), "identity/commit gate")
    }
    var challenge = V3DiagnosticProviderSequence(plan: plan); let challenged = challenge.start(now: 0)!
    challenge.needsUser(challenged); challenge.resumedByUser(challenged, now: 1)
    challenge.failed(challenged, reason: .providerRejectedInit)
    try expect(challenge.state == .stopped(.providerRejectedInit), "challenge/repair latch forbids rotation")
    for duringBackoff in [false, true] {
        var s = V3DiagnosticProviderSequence(plan: plan); let a = s.start(now: 0)!
        s.failed(a, reason: .providerRejectedInit)
        if duringBackoff { s.previousAttemptStopped(a, isolated: true, credentialsCommitted: false, now: 1) }
        s.cancel(); s.previousAttemptStopped(a, isolated: true, credentialsCommitted: false, now: 2)
        try expect(s.state == .cancelled && s.continueAfterBackoff(now: 99) == nil, "cancel during cleanup/backoff")
    }
    var exhausted = V3DiagnosticProviderSequence(plan: V3DiagnosticProviderPlan(["onDevice"])!)
    let last = exhausted.start(now: 0)!
    exhausted.failed(last, reason: .providerRejectedInit)
    exhausted.previousAttemptStopped(last, isolated: true, credentialsCommitted: false, now: 1)
    try expect(exhausted.state == .exhausted, "single selected provider is not broadened")
    for reason in [V3DiagnosticProviderSequence.Failure.invalidCredentials, .accountRestricted, .rateLimited, .invalidCode, .identityChanged, .credentialStorage, .unknown] {
        var s = V3DiagnosticProviderSequence(plan: plan); let a = s.start(now: 0)!
        s.failed(a, reason: reason)
        try expect(s.state == .stopped(reason), "unrelated failure remains terminal")
    }
    print("INITIAL_PROVIDER_REJECTION_CONSUMER_PASS actual_mapper=true actual_sequence=true account_calls=false")
}
