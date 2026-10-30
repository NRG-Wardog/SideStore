import Foundation

func fixtureCommitCredentials(_ credentials: LCEmbeddedAuthenticationSnapshot, remote: Bool,
                              ownedBy attempt: V3RemoteAnisetteAttempt? = nil) throws {
    let auth = AuthManager.shared
    auth.v3BeginIdentityTransition()
    do {
        try Keychain.shared.writeAuthenticationCredentials(
            appleID: credentials.appleIDEmailAddress!, password: credentials.appleIDPassword!,
            dsid: credentials.appleIDAdsid!, authToken: credentials.appleIDXcodeToken!, remoteProvider: remote)
        auth.v3CompleteIdentityTransition()
    } catch {
        auth.v3CompleteIdentityTransition(); throw error
    }
    attempt?.authorization?.adoptOwnedTransition(appleID: credentials.appleIDEmailAddress!,
        dsid: credentials.appleIDAdsid!, token: credentials.appleIDXcodeToken!)
}

func fixturePublishManual() async throws -> V3RemoteIdentityRecord {
    let attempt = try V3RemoteIdentityContinuity.manualAttempt()
    _ = try await attempt.context.fetch()
    try fixtureCommitCredentials(fixtureCredentialsA, remote: true, ownedBy: attempt)
    let handoff = try await attempt.handoff()
    for diagnostic in [String(describing: handoff), String(reflecting: handoff),
                       String(describing: handoff.state), String(reflecting: handoff.state)] {
        for secret in [handoff.identityID, handoff.state.identity.base64EncodedString(),
                       handoff.state.adiPB!, handoff.routeMarker.base64EncodedString()] {
            try fixtureCheck(!diagnostic.contains(secret), "handoff and state diagnostics redacted")
        }
    }
    try V3RemoteIdentityContinuity.commit(handoff, credentials: fixtureCredentialsA)
    attempt.context.invalidate()
    return try Keychain.shared.remoteIdentityRecord()!
}

func runRuntimeCases() async throws -> [String] {
    var passed: [String] = []
    func test(_ name: String, _ body: () async throws -> Void) async throws {
        fixtureRuntimeReset(); try await body(); passed.append(name)
    }

    try await test("manual_terminal_handoff_restores_new_request_clients") {
        let record = try await fixturePublishManual()
        let data = try await V3RemoteRequestLeases.withAuthorizedRoute {
            try await AnisetteProvider.fetch()
        }
        try fixtureCheck(data.identity == record.identity, "restored manual identity")
        try fixtureCheck(FixtureProviderBackend.shared.provisionCount == 1, "provision exactly once")
        try fixtureCheck(FixtureProviderBackend.shared.observed.count == 2, "new request fetch")
    }
    try await test("restart_reuses_identity_but_refreshes_profile_and_otp") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let first = try await V3RemoteRequestLeases.withAuthorizedRoute { try await AnisetteProvider.fetch() }
        FixtureProviderBackend.shared.setProfileRevision(2)
        let second = try await V3RemoteRequestLeases.withAuthorizedRoute { try await AnisetteProvider.fetch() }
        try fixtureCheck(first.identity == record.identity && second.identity == record.identity, "stable identity")
        try fixtureCheck(first.otp != second.otp, "fresh OTP")
        try fixtureCheck(first.clientInfo != second.clientInfo, "profile can refresh")
        try fixtureCheck(FixtureProviderBackend.shared.provisionCount == 0, "no reprovision")
    }
    try await test("configured_background_session_keeps_remote_continuity") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        try fixtureCheck(ILoaderRemoteAuthentication.current == nil, "no caller context")
        let session = try await AuthManager.shared.getAuthenticatedSession()
        try fixtureCheck(session.anisetteData.identity == record.identity, "background identity")
        try fixtureCheck(FixtureProviderBackend.shared.localCount == 0, "no default fallback")
        try fixtureCheck(FixtureProviderBackend.shared.provisionCount == 0, "no new identity")
    }
    try await test("unmarked_saved_tokens_require_one_manual_signin_even_with_local_pair") {
        try fixtureInstallCredentials(fixtureCredentialsA)
        try Keychain.shared.keychain.set(Data("synthetic-legacy-local-identity".utf8), key: "identifier")
        try Keychain.shared.keychain.set(Data("synthetic-legacy-local-blob".utf8), key: "adiPb")
        try fixtureThrowsRemote("unknown token provenance", expected: .manualSignInRequired) {
            _ = try V3RemoteIdentityContinuity.admittedRecord()
        }
        try await fixtureAsyncThrows("unmarked token session") {
            _ = try await AuthManager.shared.getAuthenticatedSession()
        }
        try fixtureCheck(FixtureProviderBackend.shared.observed.isEmpty && FixtureProviderBackend.shared.localCount == 0,
            "no provider acquisition before fresh signin")
        // Model only the existing verified-credential commit, not live authentication.
        try fixtureCommitCredentials(fixtureCredentialsA, remote: false)
        let local = try await AuthManager.shared.getAuthenticatedSession()
        try fixtureCheck(local.anisetteData.identity.isEmpty && FixtureProviderBackend.shared.localCount == 1,
            "fresh verified local marker restores configured continuation")
    }
    try await test("pending_remote_tokens_never_fall_back_after_interruption") {
        try fixtureCommitCredentials(fixtureCredentialsA, remote: true)
        try fixtureCheck(try Keychain.shared.remoteIdentityRouteMarker()?.mode == .pendingRemote, "pending before terminal")
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "identity not handed off")
        await Task.yield()
        try await fixtureAsyncThrows("interrupted auth") {
            _ = try await AuthManager.shared.getAuthenticatedSession()
        }
        try fixtureCheck(FixtureProviderBackend.shared.observed.isEmpty, "no remote reprovision")
        try fixtureCheck(FixtureProviderBackend.shared.localCount == 0, "no local pairing with pending tokens")
    }
    try await test("competing_first_attempt_loser_cannot_authorize_winner_identity") {
        let first = try V3RemoteIdentityContinuity.manualAttempt()
        _ = try await first.context.fetch()
        try fixtureCommitCredentials(fixtureCredentialsA, remote: true, ownedBy: first)
        let firstHandoff = try await first.handoff()
        let second = try V3RemoteIdentityContinuity.manualAttempt()
        _ = try await second.context.fetch()
        try fixtureCommitCredentials(fixtureCredentialsB, remote: true, ownedBy: second)
        let secondHandoff = try await second.handoff()
        try fixtureThrowsRemote("loser identity CAS", expected: .stateChanged) {
            try V3RemoteIdentityContinuity.commit(firstHandoff, credentials: fixtureCredentialsA)
        }
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "loser identity not published")
        try fixtureCheck(try Keychain.shared.remoteIdentityRouteMarker()?.mode == .pendingRemote, "pending token quarantined")
        try await fixtureAsyncThrows("pending winner token admission") {
            _ = try await AuthManager.shared.getAuthenticatedSession()
        }
        try V3RemoteIdentityContinuity.commit(secondHandoff, credentials: fixtureCredentialsB)
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord()?.identity == secondHandoff.state.identity, "current winner identity")
        try fixtureCheck(try Keychain.shared.remoteIdentityRouteMarker()?.binding == fixtureBinding(fixtureCredentialsB), "winner route matches current tokens")
        try fixtureCheck(FixtureProviderBackend.shared.localCount == 0, "no fallback for loser")
    }
    try await test("manual_missing_identity_storage_error_revokes_attempt") {
        let attempt = try V3RemoteIdentityContinuity.manualAttempt()
        FixtureSecurity.shared.failReads = true
        try await fixtureAsyncThrows("failed store does not mean absent") { _ = try await attempt.context.fetch() }
        try fixtureCheck(FixtureProviderBackend.shared.observed.isEmpty, "no provider fetch")
    }
    try await test("manual_attempt_is_revoked_by_account_change") {
        let attempt = try V3RemoteIdentityContinuity.manualAttempt()
        try fixtureCommitCredentials(fixtureCredentialsB, remote: false)
        try await fixtureAsyncThrows("manual account replacement") { _ = try await attempt.context.fetch() }
        try fixtureCheck(FixtureProviderBackend.shared.observed.isEmpty, "stale attempt not dispatched")
    }
    try await test("cache_hit_must_recheck_account_authorization") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let lease = try V3RemoteRequestLeases.makeLease(id: "cache-owner")!
        _ = try await lease.context.fetch()
        AuthManager.shared.v3AdvanceIdentityGeneration()
        try await fixtureAsyncThrows("revoked cache") { _ = try await lease.context.fetch() }
        try fixtureCheck(FixtureProviderBackend.shared.observed.count == 1, "no second provider dispatch")
        lease.close()
    }
    try await test("account_change_during_fetch_cannot_publish_session") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let gate = FixtureAsyncGate(); FixtureProviderBackend.shared.setGate(gate)
        let pending = Task { try await AuthManager.shared.getAuthenticatedSession() }
        try await gate.waitForArrivals(1)
        try fixtureCommitCredentials(fixtureCredentialsB, remote: false)
        await gate.release()
        try await fixtureAsyncThrows("stale session result") { _ = try await pending.value }
        try fixtureCheck(AuthManager.shared.session == nil, "not installed")
    }
    try await test("signout_preserves_identity_but_revokes_active_and_manual_contexts") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let lease = try V3RemoteRequestLeases.makeLease(id: "signout-owner")!
        let attempt = try V3RemoteIdentityContinuity.manualAttempt()
        AuthManager.shared.v3BeginIdentityTransition()
        try LCEmbeddedSharedKeychain.clearSignInInfoChecked(Keychain.shared.keychain)
        V3RemoteRequestLeases.invalidateAll(); V3RemoteRequestLeases.invalidateManualAttempts()
        AuthManager.shared.v3CompleteIdentityTransition()
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord()?.identity == record.identity, "identity preserved")
        try await fixtureAsyncThrows("old request") { _ = try await lease.context.fetch() }
        try await fixtureAsyncThrows("old manual attempt") { _ = try await attempt.context.fetch() }
    }
    try await test("reset_keeps_remote_provenance_and_requires_manual_signin") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let lease = try V3RemoteRequestLeases.makeLease(id: "reset-owner")!
        try V3RemoteIdentityContinuity.resetExplicitly()
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "reset identity")
        try fixtureCheck(try Keychain.shared.remoteIdentityRouteMarker()?.mode == .readyRemote, "marker retained")
        try await fixtureAsyncThrows("old reset lease") { _ = try await lease.context.fetch() }
        try await fixtureAsyncThrows("no new automatic identity") {
            _ = try await AuthManager.shared.getAuthenticatedSession()
        }
        try fixtureCheck(FixtureProviderBackend.shared.localCount == 0 && FixtureProviderBackend.shared.provisionCount == 0, "no provider substitution")
    }
    try await test("inherited_cancelled_context_never_acquires_replacement") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let lease = try V3RemoteRequestLeases.makeLease(id: "cancelled-owner")!
        lease.close()
        try await fixtureAsyncThrows("cancelled inherited lease") {
            try await ILoaderRemoteAuthentication.$current.withValue(lease.context) {
                _ = try await V3RemoteRequestLeases.withAuthorizedRoute { try await AnisetteProvider.fetch() }
            }
        }
        try fixtureCheck(FixtureProviderBackend.shared.observed.isEmpty, "no replacement")
    }
    try await test("duplicate_lease_id_rejected_and_stale_close_does_not_revoke_new_owner") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let first = try V3RemoteRequestLeases.makeLease(id: "reused-id")!
        try fixtureThrowsRemote("duplicate lease", expected: .stateChanged) {
            _ = try V3RemoteRequestLeases.makeLease(id: "reused-id")
        }
        first.close()
        let second = try V3RemoteRequestLeases.makeLease(id: "reused-id")!
        first.close()
        try second.context.checkActive()
        V3RemoteRequestLeases.invalidate("reused-id")
        try await fixtureAsyncThrows("new owner invalidate") { _ = try await second.context.fetch() }
    }
    try await test("coalescer_keys_keep_default_and_distinct_lease_producers_separate") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let first = try V3RemoteRequestLeases.makeLease(id: "first-key")!
        let second = try V3RemoteRequestLeases.makeLease(id: "second-key")!
        let defaultKey = V3RemoteRequestLeases.coalescerKey("same-work")
        let firstKey = ILoaderRemoteAuthentication.$current.withValue(first.context) { V3RemoteRequestLeases.coalescerKey("same-work") }
        let secondKey = ILoaderRemoteAuthentication.$current.withValue(second.context) { V3RemoteRequestLeases.coalescerKey("same-work") }
        try fixtureCheck(Set([defaultKey, firstKey, secondKey]).count == 3, "producer partition")
        let gate = FixtureAsyncGate()
        let one = Task { try await TaskChainCoalescer.shared.coalesce(key: firstKey) { await gate.arriveAndWait(); return "first" } }
        try await gate.waitForArrivals(1)
        let two = Task { try await TaskChainCoalescer.shared.coalesce(key: secondKey) { await gate.arriveAndWait(); return "second" } }
        try await gate.waitForArrivals(2)
        let plain = try await TaskChainCoalescer.shared.coalesce(key: defaultKey) { "default" }
        await gate.release()
        let values = try await [one.value, two.value]
        try fixtureCheck(values == ["first", "second"] && plain == "default", "separate results")
        withExtendedLifetime((first, second)) {}
    }
    try await test("concurrent_same_context_acquisition_does_not_create_competing_identity") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let lease = try V3RemoteRequestLeases.makeLease(id: "concurrent-owner")!
        let gate = FixtureAsyncGate(); FixtureProviderBackend.shared.setGate(gate)
        let first = Task { try await lease.context.fetch() }
        try await gate.waitForArrivals(1)
        try await fixtureAsyncThrows("reentrant acquisition") { _ = try await lease.context.fetch() }
        await gate.release()
        let data = try await first.value
        try fixtureCheck(data.identity == record.identity && FixtureProviderBackend.shared.observed.count == 1, "one acquisition")
        lease.close()
    }
    try await test("actual_route_coalescer_rechecks_admitted_local_account_before_return") {
        try fixtureCommitCredentials(fixtureCredentialsA, remote: false)
        let gate = FixtureAsyncGate()
        let pending = Task {
            try await V3RemoteRequestLeases.coalesce(key: "fixture-local-route") {
                await gate.arriveAndWait()
                return "synthetic-result"
            }
        }
        try await gate.waitForArrivals(1)
        try fixtureCommitCredentials(fixtureCredentialsB, remote: false)
        await gate.release()
        try await fixtureAsyncThrows("coalesced stale account result") { _ = try await pending.value }
        try fixtureCheck(FixtureProviderBackend.shared.observed.isEmpty && FixtureProviderBackend.shared.localCount == 0,
            "no replacement provider acquisition")
    }
    try await test("cancelled_auth_waiter_does_not_return_producer_session") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let lease = try V3RemoteRequestLeases.makeLease(id: "waiter-owner")!
        let gate = FixtureAsyncGate(); FixtureProviderBackend.shared.setGate(gate)
        let waiter = Task {
            try await ILoaderRemoteAuthentication.$current.withValue(lease.context) {
                try await AuthManager.shared.getAuthenticatedSession()
            }
        }
        try await gate.waitForArrivals(1)
        waiter.cancel(); await gate.release()
        try await fixtureAsyncThrows("cancelled waiter") { _ = try await waiter.value }
        lease.close()
    }
    try await test("actual_portal_proxy_retains_lease_through_dispatch") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let certificates = try await DeveloperPortalProxy.shared.fetchCertificates(team: .fixture)
        let observations = FixturePortalBackend.shared.observations
        try fixtureCheck(certificates.first?.identity == record.identity, "portal session identity")
        try fixtureCheck(observations.count == 1 && observations[0].1 != nil, "scoped portal transport")
        try fixtureThrows("portal lease ended") { try observations[0].1!.checkActive() }
    }
    try await test("actual_account_read_wrapper_carries_route_into_portal") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let dispatcher = await FixturePortalDispatcher()
        let response = try await dispatcher.fetchCertificates()
        let certificates = response["certificates"] as? [ALTX509Certificate]
        try fixtureCheck(certificates?.first?.identity == record.identity, "account read identity")
        try fixtureCheck(response["identityStable"] as? Bool == true, "stable account stamp")
        let observed = FixturePortalBackend.shared.observations
        try fixtureCheck(observed.count == 1 && observed[0].1 != nil, "account-scoped transport")
        try fixtureThrows("account read lease ended") { try observed[0].1!.checkActive() }
    }
    try await test("actual_portal_late_result_is_rejected_after_signout") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let gate = FixtureAsyncGate(); FixturePortalBackend.shared.setGate(gate)
        let pending = Task { try await DeveloperPortalProxy.shared.fetchCertificates(team: .fixture) }
        try await gate.waitForArrivals(1)
        AuthManager.shared.v3BeginIdentityTransition()
        try LCEmbeddedSharedKeychain.clearSignInInfoChecked(Keychain.shared.keychain)
        AuthManager.shared.v3CompleteIdentityTransition()
        await gate.release()
        try await fixtureAsyncThrows("late portal publication") { _ = try await pending.value }
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord()?.identity == record.identity, "signout kept provider identity")
    }
    try await test("actual_detached_refresh_restores_account_authorized_route") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let app = try await fixtureRunPipeline()
        let observed = FixturePortalBackend.shared.observations
        try fixtureCheck(app.anisette.identity == record.identity, "detached identity")
        try fixtureCheck(observed.count == 1 && observed[0].1 != nil, "detached route survived")
        try fixtureCheck(FixtureProviderBackend.shared.provisionCount == 0 && FixtureProviderBackend.shared.localCount == 0, "no alternate provider")
        try fixtureThrows("pipeline owned lease ended") { try observed[0].1!.checkActive() }
    }
    try await test("actual_detached_refresh_preserves_inherited_context_ownership") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let outer = try V3RemoteRequestLeases.makeLease(id: "outer-pipeline")!
        let app = try await ILoaderRemoteAuthentication.$current.withValue(outer.context) { try await fixtureRunPipeline() }
        try fixtureCheck(app.anisette.identity == record.identity, "inherited identity")
        try fixtureCheck(FixturePortalBackend.shared.observations.first?.1 === outer.context, "same inherited context")
        try outer.context.checkActive()
        outer.close()
    }
    try await test("queued_local_operation_cannot_acquire_replacement_remote_account") {
        try fixtureCommitCredentials(fixtureCredentialsA, remote: false)
        let gate = FixtureAsyncGate(); FixturePipelineBoundary.setGate(gate)
        let pending = Task { try await fixtureRunPipeline() }
        try await gate.waitForArrivals(1)
        try fixtureCommitCredentials(fixtureCredentialsB, remote: true)
        let replacement = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsB))
        try Keychain.shared.commitRemoteIdentity(replacement, replacing: nil, credentials: fixtureCredentialsB,
            expectedRoute: Keychain.shared.remoteIdentityRouteBytes()!)
        await gate.release()
        try await fixtureAsyncThrows("queued nil route account replacement") { _ = try await pending.value }
        try fixtureCheck(FixturePortalBackend.shared.observations.isEmpty, "no wrong-account portal dispatch")
        try fixtureCheck(FixtureProviderBackend.shared.observed.isEmpty && FixtureProviderBackend.shared.localCount == 0, "no wrong-account anisette")
    }
    try await test("pre_reset_handoff_cannot_resurrect_absent_identity") {
        let attempt = try V3RemoteIdentityContinuity.manualAttempt()
        _ = try await attempt.context.fetch()
        try fixtureCommitCredentials(fixtureCredentialsA, remote: true, ownedBy: attempt)
        let handoff = try await attempt.handoff()
        try V3RemoteIdentityContinuity.resetExplicitly()
        try fixtureThrowsRemote("reset before handoff commit", expected: .stateChanged) {
            try V3RemoteIdentityContinuity.commit(handoff, credentials: fixtureCredentialsA)
        }
        try fixtureCheck(try Keychain.shared.remoteIdentityRecord() == nil, "not resurrected")
    }
    try await test("actual_app_manager_refresh_carries_configured_remote_identity") {
        let record = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsA)); try fixtureSave(record)
        let outer = try V3RemoteRequestLeases.makeLease(id: "outer-refresh-completion-owner")!
        let app = try await ILoaderRemoteAuthentication.$current.withValue(outer.context) {
            try await fixtureRunAppManagerRefresh(onCompletion: { outer.close() })
        }
        try fixtureCheck(app.anisette.identity == record.identity, "outer refresh identity")
        let observed = FixturePortalBackend.shared.observations
        try fixtureCheck(observed.count == 1 && observed[0].1 != nil, "outer refresh scoped portal")
        try fixtureThrows("outer refresh owned lease ended") { try observed[0].1!.checkActive() }
    }
    try await test("actual_app_manager_queued_local_route_rejects_replacement_account") {
        try fixtureCommitCredentials(fixtureCredentialsA, remote: false)
        let gate = FixtureAsyncGate(); FixturePipelineBoundary.setGate(gate)
        let pending = Task { try await fixtureRunAppManagerRefresh() }
        try await gate.waitForArrivals(1)
        try fixtureCommitCredentials(fixtureCredentialsB, remote: true)
        let replacement = fixtureRecord(binding: try fixtureBinding(fixtureCredentialsB))
        try Keychain.shared.commitRemoteIdentity(replacement, replacing: nil, credentials: fixtureCredentialsB,
            expectedRoute: Keychain.shared.remoteIdentityRouteBytes()!)
        await gate.release()
        try await fixtureAsyncThrows("outer queued account replacement") { _ = try await pending.value }
        try fixtureCheck(FixturePortalBackend.shared.observations.isEmpty && FixtureProviderBackend.shared.observed.isEmpty,
            "outer queue cannot dispatch replacement account")
    }
    try await test("actual_background_callback_returns_immediate_admission_failure") {
        try fixtureInstallCredentials(fixtureCredentialsA)
        let operation = BackgroundRefreshAppsOperation()
        let results = try await operation.runFixture([.fixture])
        try fixtureCheck(results.count == 1 && operation.activeRefreshGroup == nil, "callback resumed and released group")
        try fixtureCheck(operation.persistedVerificationGroup != nil &&
            operation.persistedResultIDs == Set(results.keys) && operation.persistedAttemptedIDs == ["fixture.app"] &&
            operation.persistedRunID == "11111111-2222-3333-4444-555555555555" &&
            operation.persistedVerificationGroup?.boundTransportRunID == operation.persistedRunID,
            "actual callback preserves the group and exact target results for verification persistence")
        try fixtureThrowsRemote("background migration failure", expected: .manualSignInRequired) {
            _ = try results["fixture.app"]!.get()
        }
        try fixtureCheck(FixtureProviderBackend.shared.observed.isEmpty && FixtureProviderBackend.shared.localCount == 0,
            "failed background admission never acquired provider")
    }
    return passed
}
