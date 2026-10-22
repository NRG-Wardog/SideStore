import Foundation

struct FixtureAssertion: Error { let message: String }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw FixtureAssertion(message: message) }
}
func expectFailure(_ op: DeferredFixtureOperation) async throws {
    var failed = false
    do { _ = try await op.run() } catch { failed = true }
    try require(failed && !Boundary.events.contains("returned"), "Failed path must not return a successful result")
}

@main struct DeferredSetupTests {
    static func main() async throws {
        try SyntheticSigningIdentity.configure()
        if CommandLine.arguments.contains("--expect-prior-pem-rejection") {
            Boundary.reset()
            try require(V3PendingCertificateKeyProof.matches(certificateDER: Boundary.certificateDER,
                privateKeyPEM: Boundary.privateKeyPEM), "Owned fresh PEM has real matching public-key proof")
            try require(!V3PendingCertificateKeyProof.matches(certificateDER: Boundary.certificateDER,
                privateKeyDER: Boundary.privateKeyPEM), "The strict DER-only entry point rejects PEM")
            var rejected = false
            do { _ = try await DeferredFixtureOperation().run() }
            catch is V3ProvisioningResumeUnavailableError { rejected = true }
            try require(rejected && Boundary.events.contains("verifyCertificate") &&
                !Boundary.events.contains("activateChecked"), "Exact prior source must reject valid PEM before account activation")
            print("DEFERRED_PRIOR_PEM_REJECTION_REPRODUCED")
            return
        }
        var cases: [String] = []
        Boundary.reset(); Boundary.fileState = "configured"
        let configured = DeferredFixtureOperation(); _ = try await configured.run()
        try require(configured.v3DidCompleteProvisioning && !configured.v3DidDeferDeviceSetup, "Configured success remains full provisioning")
        try require(Boundary.events.contains("register") && Boundary.events.contains("activateChecked"), "Configured path registers and activates")
        cases.append("configured_success_registers_and_completes")

        Boundary.reset()
        let missing = DeferredFixtureOperation(); _ = try await missing.run()
        try require(missing.v3DidDeferDeviceSetup && !missing.v3DidCompleteProvisioning, "Missing pairing is intentional incomplete setup")
        try require(Boundary.events == ["team", "saveInactive", "certificate", "saveCertificate", "verifyCertificate", "activateChecked", "handlerComplete", "returned"], "Deferral requires certificate and checked activation, no device work")
        cases.append("missing_pairing_defers_after_certificate_and_checked_activation")

        Boundary.reset(); Boundary.fileState = "stale-file"; UserDefaults.standard.isPairingReset = true
        let reset = DeferredFixtureOperation(); _ = try await reset.run()
        try require(reset.v3DidDeferDeviceSetup && UserDefaults.standard.isPairingReset, "Reset is respected and stale bytes are never adopted")
        cases.append("reset_pairing_defers_without_adopting_stale_record")

        for record in ["invalid", "empty", "unreadable", "wrong-protocol"] {
            Boundary.reset(); Boundary.fileState = record; Boundary.failure = "udid"
            let op = DeferredFixtureOperation(); try await expectFailure(op)
            try require(!op.v3DidDeferDeviceSetup && Boundary.events.contains("register"), "Existing or unreadable records cannot be relabeled missing")
        }
        Boundary.reset(); Boundary.bundled = true
        try require(!PairingFileManager.shared.v3DeviceSetupIsUnconfigured, "Bundled data is not absence")
        for embedded in ["", "invalid", "prefix <insert pairing file here>", 42] as [Any] {
            Boundary.reset(); Boundary.embedded = embedded
            try require(!PairingFileManager.shared.v3DeviceSetupIsUnconfigured, "Malformed embedded data is not absence")
        }
        Boundary.reset(); Boundary.embedded = "<insert pairing file here>"
        try require(PairingFileManager.shared.v3DeviceSetupIsUnconfigured, "Exact shipped placeholder is unconfigured")
        cases.append("present_invalid_empty_and_unreadable_never_defer")

        for failure in ["network", "udid", "portal", "certificate", "certificateSave", "team"] {
            Boundary.reset(); Boundary.fileState = "configured"; Boundary.failure = failure
            let op = DeferredFixtureOperation(); try await expectFailure(op)
            try require(!op.v3DidDeferDeviceSetup && !op.v3DidCompleteProvisioning, "Real failures never become deferred success")
        }
        cases.append("network_udid_portal_and_certificate_failures_never_defer")

        for mode in ["background", "retry", "reauth", "skipDevice", "skipCertificate", "partial", "pendingActivation"] {
            Boundary.reset(); let op = DeferredFixtureOperation()
            switch mode {
            case "background": op.v3RequireInteractiveCredentials = false
            case "retry": op.v3ForceProvisioningRetry = true
            case "reauth": op.v3ReauthenticateAppleID = "fixture@example.invalid"
            case "skipDevice": op.skipDeviceRegistration = true
            case "skipCertificate": op.skipCertificateProvisioning = true
            case "partial": op.v3RequireFullProvisioning = false
            default: op.v3FinishPendingCertificateActivation = true
            }
            if mode == "pendingActivation" { try await expectFailure(op) } else { _ = try await op.run() }
            try require(!op.v3DidDeferDeviceSetup, "Deferral is manual full setup only")
        }
        cases.append("background_retry_reauth_and_skip_modes_never_defer")

        Boundary.reset(); Boundary.failure = "activation"
        let failedActivation = DeferredFixtureOperation(); try await expectFailure(failedActivation)
        try require(Boundary.events.contains("activateChecked") && !Boundary.events.contains("handlerComplete"), "Activation must verify before completion")
        cases.append("failed_activation_never_publishes_deferred_success")

        for failure in ["stale", "session", "owner", "account", "team", "key"] {
            Boundary.reset()
            switch failure {
            case "stale": AuthManager.shared.v3IdentityIsStable = false
            case "session": Boundary.sessionMatches = false
            case "owner": Boundary.team.account?.appleID = "other@example.invalid"
            case "account": Boundary.team.account?.identifier = "other-account"
            case "team": Boundary.certificate.x509.organizationalUnit = "OTHER"
            default: Boundary.certificate.privateKey = Boundary.wrongPrivateKeyDER
            }
            let op = DeferredFixtureOperation(); try await expectFailure(op)
            try require(!Boundary.events.contains("activateChecked"), "Wrong identity/key must fail before activating account")
        }
        cases.append("stale_identity_wrong_team_or_key_never_activates")

        Boundary.reset(); let cancelled = DeferredFixtureOperation(); cancelled.isCancelled = true
        try await expectFailure(cancelled); try require(Boundary.events.isEmpty, "Precancelled attempt does no work")
        Boundary.reset(); Boundary.cancelAtActivation = true
        try await expectFailure(DeferredFixtureOperation())
        try require(!Boundary.events.contains("handlerComplete"), "Cancellation after save is not success")
        Boundary.reset(); Boundary.changeIdentityAtActivation = true
        try await expectFailure(DeferredFixtureOperation())
        try require(!Boundary.events.contains("handlerComplete"), "Identity change across activation is not success")
        Boundary.reset()
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await expectFailure(DeferredFixtureOperation())
        }
        try await cancelledTask.value
        try require(Boundary.events.isEmpty, "Task cancellation is respected")
        cases.append("cancellation_before_or_during_activation_never_succeeds")

        Boundary.reset(); _ = try await DeferredFixtureOperation().run()
        try require(!Boundary.events.contains("register") && !Boundary.events.contains("resign") && !Boundary.events.contains("postAuth"), "Deferred flow skips device work")
        Boundary.reset(); Boundary.fileState = "configured"; _ = try await DeferredFixtureOperation().run()
        try require(Boundary.events.contains("resign") && Boundary.events.contains("postAuth"), "Normal post-auth remains intact")
        cases.append("deferred_completion_skips_resign_and_postauth")

        func intentional(_ state: String? = "authenticatedProvisioningIncomplete", _ outcome: String? = "setupDeferred", _ reason: String? = "pairingUnconfigured", _ auth: Bool = true, _ failure: Bool = false) -> Bool {
            V3DeviceSetupDeferralPolicy.isIntentionalOutcome(state: state, outcome: outcome, reason: reason, authenticated: auth, hasFailure: failure)
        }
        try require(intentional(), "Exact intentional outcome accepted")
        try require(!intentional("completed") && !intentional("failed") && !intentional(nil), "State allowlist")
        try require(!intentional("authenticatedProvisioningIncomplete", "provisioningFailed") && !intentional("authenticatedProvisioningIncomplete", "provisioningCancelled"), "Failure/cancellation not deferred")
        try require(!intentional("authenticatedProvisioningIncomplete", "setupDeferred", "network"), "Reason allowlist")
        try require(!intentional("authenticatedProvisioningIncomplete", "setupDeferred", "pairingUnconfigured", false) && !intentional("authenticatedProvisioningIncomplete", "setupDeferred", "pairingUnconfigured", true, true), "Authentication and absence of failure required")
        cases.append("wire_outcome_allowlist_preserves_incomplete_journal")

        func completeAndExport(_ key: Data) async throws -> (DeferredServiceFixture, SignInResult) {
            Boundary.reset(); Boundary.certificate.privateKey = key
            V3HeadlessRuntime.shared.auth.hasActiveSession = true
            let operation = DeferredFixtureOperation()
            let result = try await operation.run()
            try require(DatabaseManager.shared.activeAccount()?.identifier == result.team.account?.identifier &&
                DatabaseManager.shared.activeTeam()?.identifier == result.team.identifier,
                "Checked finalization activates the exact owned account and team")
            let service = DeferredServiceFixture()
            try service.complete(operation: operation, result: result)
            try require(Array(Boundary.events.suffix(2)) == ["identityCommit:nil", "serviceTerminal"] &&
                Boundary.events.filter { $0 == "identityCommit:nil" }.count == 1,
                "Actual terminal publishes only after the owned nil-handoff boundary returns once")
            guard let terminal = service.terminal else { throw FixtureAssertion(message: "Actual deferred branch must publish terminal") }
            let wire = try JSONSerialization.data(withJSONObject: terminal, options: [.sortedKeys])
            guard let decoded = try JSONSerialization.jsonObject(with: wire) as? [String: Any] else { throw FixtureAssertion(message: "Terminal must round-trip") }
            try require(V3DeviceSetupDeferralPolicy.isIntentionalOutcome(state: decoded["state"] as? String,
                outcome: decoded["outcome"] as? String, reason: decoded["setupDeferredReason"] as? String,
                authenticated: decoded["authenticated"] as? Bool == true, hasFailure: decoded["failure"] != nil),
                "Serialized actual service terminal remains authenticated intentional incompletion")
            try require(!operation.v3DidCompleteProvisioning && !Boundary.events.contains("register") &&
                !Boundary.events.contains("resign") && !Boundary.events.contains("postAuth"), "No false setup completion or device work")
            var activeSessionBlocked = false
            do { _ = try service.exportActive() } catch ServiceError.notFound { activeSessionBlocked = true }
            try require(activeSessionBlocked, "Export remains blocked until the authentication owner settles")
            V3HeadlessRuntime.shared.auth.hasActiveSession = false
            let exported = try service.exportActive()
            try require(exported["data"] as? Data == Boundary.syntheticP12 &&
                exported["teamIdentifier"] as? String == result.team.identifier &&
                (exported["identitySHA256"] as? String)?.count == 64,
                "Actual export guards and adapter return this owned synthetic certificate tuple")
            return (service, result)
        }
        _ = try await completeAndExport(Boundary.privateKeyPEM)
        cases.append("fresh_pem_real_proof_finalization_terminal_and_export")
        _ = try await completeAndExport(Boundary.privateKeyDER)
        _ = try await completeAndExport(Boundary.privateKeyPKCS8)
        cases.append("reloaded_pkcs1_and_pkcs8_real_proof_finalization_terminal_and_export")

        let malformedPEM = Data("-----BEGIN RSA PRIVATE KEY-----\ninvalid-base64\n-----END RSA PRIVATE KEY-----\n".utf8)
        let unsupportedPEM = Data(("-----BEGIN PRIVATE KEY-----\n" + Boundary.privateKeyPKCS8.base64EncodedString() + "\n-----END PRIVATE KEY-----\n").utf8)
        for key in [Boundary.wrongPrivateKeyDER, malformedPEM, unsupportedPEM,
                    Data(Boundary.privateKeyDER.dropLast()), Data(), Data([2])] {
            Boundary.reset(); Boundary.certificate.privateKey = key
            try await expectFailure(DeferredFixtureOperation())
            try require(!Boundary.events.contains("activateChecked") && DatabaseManager.shared.activeAccount() == nil,
                "Unproved key material cannot activate an account")
        }
        cases.append("real_proof_rejects_wrong_malformed_and_truncated_keys")

        for failure in ["missingAccount", "missingTeam", "accountOwner", "teamOwner", "teamID", "activeCertificate", "sessionOwner", "cancelled", "mode", "missingCredentials"] {
            Boundary.reset()
            let operation = DeferredFixtureOperation(); let result = try await operation.run()
            let service = DeferredServiceFixture()
            switch failure {
            case "missingAccount": DatabaseManager.shared.account = nil
            case "missingTeam": DatabaseManager.shared.team = nil
            case "accountOwner": DatabaseManager.shared.account?.appleID = "other@example.invalid"
            case "teamOwner": DatabaseManager.shared.team?.account?.identifier = "other-account"
            case "teamID": DatabaseManager.shared.team?.identifier = "OTHER"
            case "activeCertificate": CertificateManager.shared.activeCertificate?.certificate.x509.data = Data([1])
            case "sessionOwner": service.ownsSession = false
            case "cancelled": service.sessions[service.sessionID]?.cancellationRequested = true
            case "missingCredentials": AuthManager.shared.authenticationSnapshot = nil
            default: service.sessions[service.sessionID]?.mode = .resumeProvisioning
            }
            var blocked = false
            do { try service.complete(operation: operation, result: result) }
            catch is V3ProvisioningResumeUnavailableError { blocked = true }
            try require(blocked && service.terminal == nil && service.resumableProvisioning == nil &&
                !Boundary.events.contains("identityCommit:nil") && !Boundary.events.contains("serviceTerminal"),
                "Missing credentials or lost ownership must fail before identity commit or terminal/journal success")
        }
        Boundary.reset()
        // This boundary check must also compile against the frozen pre-handoff
        // SignInResult used by the historical PEM rejection control.
        var remoteCommitBlocked = false
        do { try V3RemoteIdentityContinuity.commit(V3RemoteIdentityHandoff(), credentials: Credentials()) }
        catch V3RemoteIdentityError.stateChanged { remoteCommitBlocked = true }
        try require(remoteCommitBlocked && !Boundary.events.contains("identityCommit:nil") &&
            !Boundary.events.contains("serviceTerminal"),
            "Unsupported remote handoff cannot silently pass the inert persistence boundary")
        for failure in ["missingAccount", "missingTeam", "accountOwner", "teamOwner", "unstable", "signedOut", "missingCertificate", "emptyTeam", "activeSession"] {
            let (service, _) = try await completeAndExport(Boundary.privateKeyPEM)
            switch failure {
            case "missingAccount": DatabaseManager.shared.account = nil
            case "missingTeam": DatabaseManager.shared.team = nil
            case "accountOwner": DatabaseManager.shared.account?.appleID = "other@example.invalid"
            case "teamOwner": DatabaseManager.shared.team?.account?.identifier = "other-account"
            case "unstable": AuthManager.shared.v3IdentityIsStable = false
            case "signedOut": AuthManager.shared.authenticationSnapshot?.isAuthenticated = false
            case "missingCertificate": CertificateManager.shared.activeCertificate = nil
            case "emptyTeam": DatabaseManager.shared.team?.identifier = ""
            default: V3HeadlessRuntime.shared.auth.hasActiveSession = true
            }
            var blocked = false
            do { _ = try service.exportActive() } catch ServiceError.notFound { blocked = true }
            try require(blocked, "Certificate export keeps every account/team/session gate")
        }
        cases.append("service_terminal_and_export_reject_mismatched_ownership")

        let result: [String: Any] = ["schema": "deferred-device-setup-cases-v1", "fake_only": true, "cases": cases]
        if CommandLine.arguments.count > 1 {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("DEFERRED_DEVICE_SETUP_FIXTURE_PASS")
    }
}
