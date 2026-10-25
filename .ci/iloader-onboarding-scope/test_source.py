#!/usr/bin/env python3
"""Offline source/projection checks. Does not compile or execute Swift."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import tempfile
import unittest
import generate

ROOT = generate.ROOT
SIGN = ROOT.parent / "SideSign"
CASES = {
    "authenticated-session-to-queued-fetchTeams-and-finalization",
    "real-coalescer-default-and-two-attempts-isolation",
    "nil-phase-wrappers-clear-unrelated-ambient-context",
    "revoked-during-version-await-no-install-no-dispatch-no-fallback",
    "cancelled-waiter-rejects-unstructured-coalescer-result",
    "queued-identity-change-rejected-before-install-and-dispatch",
    "remote-provider-failure-never-selects-local-fallback",
    "cancelled-attempt-sentinel-and-next-independent-default",
}

REGISTRATION_CASES = ['registration-live-and-fallback-preserve-first', 'registration-wrapped-minimuxer-cause', 'registration-fallback-error-without-first-error', 'registration-missing-verified-identifier', 'registration-local-list-auth-before-response', 'registration-local-list-auth-after-http200', 'registration-list-parser-response', 'registration-conditional-register-portal-error', 'registration-unknown-cycle', 'registration-deep-chain-truncated', 'registration-decoder-unknown-key', 'registration-oversize-payload', 'registration-wrapped-native-cause', 'registration-preserves-existing-observers']

def read(path): return (ROOT / path).read_text()
def sha(text): return hashlib.sha256(text.encode()).hexdigest()

class OnboardingSourceTests(unittest.TestCase):
    def test_provider_default_body_is_byte_identical_after_explicit_branch(self):
        method = generate.extract(read("SideStore/Core/Anisette/AnisetteProvider.swift"), "static func fetch(handler:")
        start = method.index("        // A latched attempt")
        route = "        if V3DiagnosticProviderRoute.current == .onDevice ||\n            (V3DiagnosticProviderRoute.current == nil && UserDefaults.standard.useOnDeviceAnisette) {"
        self.assertEqual(method.count(route), 1)
        end = method.index(route)
        branch = method[start:end]
        self.assertIn("if let remote = ILoaderRemoteAuthentication.current", branch)
        self.assertIn("return try await remote.fetch()", branch)
        self.assertNotIn("catch", branch)
        self.assertEqual(sha(method[:start] + method[end:].replace(route, "        if UserDefaults.standard.useOnDeviceAnisette {", 1)), "f5554f878bc6146851d4ba29bca6766202323f5806c970edaa9a37dcc2e546a4")

    def test_phase_scope_and_existing_cancellation_are_preserved(self):
        operation = read("SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift")
        for anchor in ["private func provisioningLoop(account:", "private func finalizeAuthentication(result:"]:
            body = generate.extract(operation, anchor)
            self.assertIn("ILoaderRemoteAuthentication.$current.withValue(self.v3RemoteContextSnapshot())", body)
            self.assertLess(body.index("withValue("), body.index("v3LoginStage("))
        for anchor, expected in {
            "override func execute(parentProgress:": "4a54bc14ab7ddc95f4dff023db39d91ca5f87101998a1284745d5bac81722b1a",
            "override func cancel()": "7a9ce1149a862281983bea580a0b8729b8c8669307b09123e9ccdd93f315f700",
        }.items(): self.assertEqual(sha(generate.extract(operation, anchor)), expected)
        diagnostic = generate.extract(operation, "private func diagnosticAuthentication(appleID:")
        self.assertNotIn("v3RemoteAnisetteContext = nil", operation.replace(diagnostic, ""))
        self.assertEqual(diagnostic.count("v3RemoteAnisetteContext = nil"), 1)
        ordered = ["guard v3RequireInteractiveCredentials", "while true", "try Task.checkCancellation()",
                   "guard !isCancelled", "v3RemoteContextSnapshot()?.invalidate()",
                   "v3RemoteAnisetteLock.withLock", "v3RemoteAnisetteContext = nil",
                   "withThrowingTaskGroup", "defer { group.cancelAll() }", "} catch {",
                   "if isCancelled || Task.isCancelled || v3IsAuthCancellation(error) { throw error }",
                   "if challengeSeen { sequence.needsUser(attempt) }", "sequence.failed(attempt, reason: failure)",
                   "guard case .stopping", "sequence.previousAttemptStopped(attempt,",
                   "guard case .backoff", "try await Task.sleep(nanoseconds: UInt64(2 * (attempt.index + 1))",
                   "sequence.continueAfterBackoff", "attempt = next"]
        positions = [diagnostic.index(value) for value in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("credentialsCommitted: identityStamp != AuthManager.shared.v3IdentityStamp", diagnostic)
        self.assertIn("isolated: AuthManager.shared.v3IdentityIsStable", diagnostic)
        installed = diagnostic.index("v3RemoteAnisetteContext = remote.context")
        admitted = diagnostic.index("v3AnisetteRouteResolved = true", installed)
        self.assertIn("if isCancelled || Task.isCancelled {", diagnostic[installed:admitted])
        self.assertIn("v3RemoteContextSnapshot()?.invalidate()", diagnostic[installed:admitted])
        self.assertIn("throw CancellationError()", diagnostic[installed:admitted])
        child = diagnostic[diagnostic.index("group.addTask {"):diagnostic.index("let result = try await self.signIn")]
        self.assertIn("guard !self.isCancelled, !Task.isCancelled else { throw CancellationError() }", child)
        auth = generate.extract(operation, "private func performSignIn(appleID:")
        pre_apple = auth[auth.index("await v3DiagnosticAttemptClock?.willAuthenticate()"):auth.index("let (account, session)")]
        self.assertIn("guard !isCancelled, !Task.isCancelled else { throw CancellationError() }", pre_apple)
        self.assertIn("try v3RemoteContextSnapshot()?.checkActive()", pre_apple)
        provisioning = generate.extract(operation, "private func provisioningLoop(account:")
        self.assertIn("V3DiagnosticProviderRoute.$current.withValue(self.v3DiagnosticProvider)", provisioning)

    def test_real_coalescer_and_explicit_capture_partition_rebind(self):
        actual = generate.extract(read("SideStore/Utils/concurrency/TaskChainCoalescer.swift"), "actor TaskChainCoalescer {")
        self.assertEqual(sha(actual), "482fb5e39a2942d45965163773be92120deac30ff509a8740d6fc9e33c4f7a11")
        method = generate.extract(read("SideStore/Core/Auth/AuthManager.swift"), "public func getAuthenticatedSession()")
        self.assertLess(method.index("let admission = try V3RemoteRequestLeases.admitted ?? V3RemoteRequestLeases.capture()"), method.index("TaskChainCoalescer.shared.coalesce"))
        self.assertIn('defaultKey + ".remoteAttempt.\\(ObjectIdentifier($0))" } ?? defaultKey', method)
        self.assertIn("let remoteContext = admission.context", method)
        self.assertIn("try await admission.withScope", method)
        self.assertIn("try admission.check()\n        return session", method)
        for forbidden in ["Task.detached", "UserDefaults", "setPassword", "setObject"]:
            self.assertNotIn(forbidden, method)

    def test_revocation_order_and_identity_guards(self):
        method = generate.extract(read("SideStore/Core/Auth/AuthManager.swift"), "public func getAuthenticatedSession()")
        start = method.index("if remoteContext != nil {")
        middle = method.index("} else {", start)
        end = method.index("let credentialSnapshotAfter:", middle)
        remote, local = method[start:middle], method[middle:end]
        self.assertLess(remote.index("resolvedXcodeVersion()"), remote.index("AnisetteProvider.fetch()"))
        self.assertLess(local.index("AnisetteProvider.fetch()"), local.index("resolvedXcodeVersion()"))
        for guard in ["self.v3IdentityIsStable", "self.v3IdentityStamp == identityAtStart.stamp",
                      "credentialSnapshotAfter?.appleIDAdsid == adsid",
                      "credentialSnapshotAfter?.appleIDXcodeToken == xcodeToken",
                      "self.v3InstallSessionIfCurrent(session, capturedStamp: identityAtStart.stamp)"]:
            self.assertIn(guard, method)
        self.assertNotIn("await", method[end:method.index("// A cancelled waiter")])

    def test_exact_runtime_cases_and_offline_boundaries(self):
        runtime = (generate.HERE / "RuntimeTests.swift").read_text()
        labels = re.findall(r'rows.append\("([^\"]+)"\)', runtime)
        self.assertEqual(set(labels), CASES)
        self.assertEqual(len(labels), 8)
        self.assertIn("exit(2)", runtime)
        self.assertIn("20_000_000_000", runtime)
        self.assertIn("matching: { $0 is CancellationError }", runtime)
        self.assertIn('reasonCode == "consentRequired"', runtime)
        self.assertIn('rows.count == 8', runtime)
        for name in ["BoundaryDoubles.swift", "OperationBoundaries.swift", "RuntimeTests.swift", "RegistrationDoubles.swift", "RegistrationDiagnosticDoubles.swift", "RegistrationCases.swift"]:
            text = (generate.HERE / name).read_text()
            for forbidden in ["URLSession.shared", ".data(for:", "dataTask(", "Process(", "SecItem", "dlopen("]:
                self.assertNotIn(forbidden, text)

    def test_registration_producer_and_fixture_contract(self):
        operation = read("SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift")
        body = generate.extract(operation, "private func registerCurrentDevice(for team:")
        self.assertIn("deviceQueryError = deviceQueryError ?? error", body)
        self.assertIn("if let deviceQueryError { throw cause.failure(deviceQueryError, phase: .missingVerifiedID) }", body)
        expected_calls = ["await CellularRefreshManager.shared.turnOffDataIfNeeded()", "deviceUDID = try await fetchUDID()", "deviceUDID = try await fetchUDID(useStatic: true)", "DeveloperPortalProxy.shared.fetchDevices(for: team, types: .all)", "DeveloperPortalProxy.shared.registerDevice(name: deviceName, identifier: udid, type: DeveloperPortalProxy.currentDeviceType, team: team)"]
        positions = [body.index(value) for value in expected_calls]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("safeFetchUDID", body)
        self.assertEqual(body.count("turnOnDataIfNeeded(addOnDelay: 2.0)"), 2)
        recorder = generate.extract(operation, "private struct V3ProvisioningCauseRecorder {")
        for forbidden in ["localizedDescription", "String(describing:", "Mirror(", "NSMultipleUnderlyingErrorsKey", "Task.detached", "UserDefaults", "Keychain"]:
            self.assertNotIn(forbidden, recorder)
        self.assertIn("depth < 4, visited < 8", recorder)
        self.assertIn("payload.utf8.prefix(4097)", recorder)
        self.assertIn("if v3IsAuthCancellation(error) { return error }", recorder)
        self.assertIn("let roots = chains.compactMap", recorder)
        self.assertIn("wrapper.error", recorder)
        self.assertIn("wrapper.wrappedError", recorder)
        self.assertEqual(recorder.count("native.userInfo["), 1)
        fixture = (generate.HERE / "RegistrationCases.swift").read_text()
        labels = re.findall(r'(?:failed\(|cases.append\(\()"([^\"]+)"', fixture)
        self.assertEqual(labels, REGISTRATION_CASES)
        self.assertEqual(len(labels), 14)
        for expected in ["catch is CancellationError", "catch let error as URLError", "SECRET_PASSWORD_CANARY", "cycle.next = nil", "listResult = 0", "previous observers", "fallback:true"]:
            if expected == "previous observers": expected = "prior observers forwarded exactly once"
            self.assertIn(expected, fixture)
        runtime = (generate.HERE / "RuntimeTests.swift").read_text()
        self.assertIn("registrationFixtureCases()", runtime)
        self.assertIn('appendingPathComponent("registration-cases.json")', runtime)
        self.assertIn('let schema = "device-registration-cause-cases-v1"', runtime)

    def test_generated_projection_and_source_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            evidence = generate.generate(target, ROOT, SIGN)
            self.assertEqual(set(p.name for p in target.iterdir()), set(generate.OUTPUTS) | {"source-evidence.json"})
            generated = (target / "CandidateOnboarding.swift").read_text()
            self.assertEqual(evidence["schema"], "iloader-onboarding-scope-source-evidence-v1")
            self.assertFalse(evidence["network"])
            self.assertFalse(evidence["native_provider"])
            self.assertFalse(evidence["swift_executed"])
            self.assertEqual(evidence["output_closure"], list(generate.OUTPUTS))
            for entry in evidence["production_extracts"]:
                repository, relative = entry["source"].split("/", 1)
                source = ((ROOT if repository == "SideStore" else SIGN) / relative).read_text()
                body = generate.extract(source, entry["anchor"])
                self.assertEqual(entry["sha256"], sha(body))
                if repository == "SideSign": body = re.sub(r"\bURLSession\b", "FakeSession", body)
                self.assertIn(body, generated)
            # Every lease entry used by the exact extracted lifecycle must be
            # present on this suite's typed inert boundary before native compile.
            boundary = generate.extract((target / "BoundaryDoubles.swift").read_text(),
                                        "enum V3RemoteRequestLeases {")
            declared = set(re.findall(r"static (?:func|var) (\w+)", boundary))
            required = set(re.findall(r"V3RemoteRequestLeases\.\$?(\w+)", generated))
            self.assertLessEqual(required, declared)
            self.assertIn("invalidateManualAttempts", required)
            runtime = (target / "RuntimeTests.swift").read_text()
            self.assertIn('["leaseInvalidation:regular", "leaseInvalidation:manual"]', runtime)
            for name, expected in evidence["outputs"].items():
                self.assertEqual(hashlib.sha256((target / name).read_bytes()).hexdigest(), expected)
            for path, expected in evidence["inputs"].items():
                repository, relative = path.split("/", 1)
                self.assertEqual(hashlib.sha256(((ROOT if repository == "SideStore" else SIGN) / relative).read_bytes()).hexdigest(), expected)

    def test_generation_is_deterministic(self):
        with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two:
            a = generate.generate(Path(one), ROOT, SIGN)
            b = generate.generate(Path(two), ROOT, SIGN)
            self.assertEqual(a, b)
            self.assertEqual(len(a["production_extracts"]), 54)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sidestore-root", type=Path, default=ROOT)
    parser.add_argument("--sidesign-root", type=Path)
    args, remaining = parser.parse_known_args()
    ROOT = args.sidestore_root
    SIGN = args.sidesign_root or ROOT.parent / "SideSign"
    unittest.main(argv=[__file__] + remaining)
