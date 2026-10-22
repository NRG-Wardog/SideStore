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
            default: Boundary.keyMatches = false
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

        let result: [String: Any] = ["schema": "deferred-device-setup-cases-v1", "fake_only": true, "cases": cases]
        if CommandLine.arguments.count > 1 {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("DEFERRED_DEVICE_SETUP_FIXTURE_PASS")
    }
}
