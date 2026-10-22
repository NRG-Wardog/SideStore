    // Only surrounding app/database/UI work is synthetic; the methods appended by
    // generate.py are copied unchanged from the candidate source.
    private let v3RemoteAnisetteLock = NSLock()
    private var v3RemoteAnisetteContext: ILoaderRemoteAuthenticationContext?
    let loginDiagnosticTrace = LoginDiagnosticTrace()
    let authenticationDiagnosticTrace = AuthenticationDiagnosticTrace()
    let signInHandler = FixtureHandler()
    let anisetteServerHandler = FixtureHandler()
    init(context: ILoaderRemoteAuthenticationContext?) { v3RemoteAnisetteContext = context }
    func verboseLog(_ value: String) {}
    func debugLog(_ value: String) {}

    private func executeLoginPipeline(parentProgress: Progress?) async throws -> SignInResult {
        let (account, session) = try await signIn(appleID: "fixture@example.invalid", password: "synthetic-password")
        // This is deliberately OUTSIDE signIn's TaskLocal. Production wrappers must
        // explicitly restore the latched route for the queued portal continuation.
        try expect(ILoaderRemoteAuthentication.current == nil, "signIn scope ends before onboarding")
        let result = try await provisioningLoop(account: account, session: session, reportProgress: { _ in })
        try await finalizeAuthentication(result: .success(result))
        return result
    }
    private func performSignIn(appleID: String, password: String,
                              recoveryCandidate: LCEmbeddedAuthenticationCandidate? = nil,
                              capturedStamp: String? = nil) async throws -> (ALTAccount, ALTAppleAPISession) {
        // The separate auth parity suite exercises production SRP/2FA. This suite
        // starts with a synthetic successful Apple response and no external I/O.
        let data = try await getAnisetteData()
        FixtureLog.shared.record("auth:" + data.route)
        return (ALTAccount(appleID: appleID), ALTAppleAPISession(dsid: "synthetic-dsid", authToken: "synthetic-token",
                    anisetteData: data, xcodeVersion: "synthetic-version"))
    }
    private func performProvisioningLoop(account: ALTAccount, session: ALTAppleAPISession,
                                        reportProgress: @escaping @Sendable (Int64) -> Void) async throws -> SignInResult {
        let team = try await fetchTeam(for: account, session: session)
        return SignInResult(team: team, certificate: nil, session: session)
    }
    private func performFinalizeAuthentication(result: Result<SignInResult, Error>) async throws {
        let result = try result.get()
        // Represents a final portal validation. Its route is exercised through the
        // real proxy and coalescer, without certificate creation/device mutation.
        let teams = try await DeveloperPortalProxy.shared.fetchTeams(for: result.team.account)
        FixtureLog.shared.record("finalize:" + teams[0].route)
    }
    func fixturePhaseWrappers() async throws -> String {
        let account = ALTAccount(appleID: "fixture@example.invalid")
        let result = try await provisioningLoop(account: account, session: syntheticSession("placeholder"), reportProgress: { _ in })
        try await finalizeAuthentication(result: .success(result))
        return result.team.route
    }
