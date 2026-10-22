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

def read(path): return (ROOT / path).read_text()
def sha(text): return hashlib.sha256(text.encode()).hexdigest()

class OnboardingSourceTests(unittest.TestCase):
    def test_provider_default_body_is_byte_identical_after_explicit_branch(self):
        method = generate.extract(read("SideStore/Core/Anisette/AnisetteProvider.swift"), "static func fetch(handler:")
        start = method.index("        // A latched attempt")
        end = method.index("        if UserDefaults.standard.useOnDeviceAnisette")
        branch = method[start:end]
        self.assertIn("if let remote = ILoaderRemoteAuthentication.current", branch)
        self.assertIn("return try await remote.fetch()", branch)
        self.assertNotIn("catch", branch)
        self.assertEqual(sha(method[:start] + method[end:]), "f5554f878bc6146851d4ba29bca6766202323f5806c970edaa9a37dcc2e546a4")

    def test_phase_scope_and_existing_cancellation_are_preserved(self):
        operation = read("SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift")
        for anchor in ["private func provisioningLoop(account:", "private func finalizeAuthentication(result:"]:
            body = generate.extract(operation, anchor)
            self.assertIn("ILoaderRemoteAuthentication.$current.withValue(self.v3RemoteContextSnapshot())", body)
            self.assertLess(body.index("withValue("), body.index("v3LoginStage("))
        for anchor, expected in {
            "override func execute(parentProgress:": "deb268734138448d2b8c80e77f2bf151b3dc2b04d6a768a652e1ef844ba76833",
            "override func cancel()": "7a9ce1149a862281983bea580a0b8729b8c8669307b09123e9ccdd93f315f700",
        }.items(): self.assertEqual(sha(generate.extract(operation, anchor)), expected)
        self.assertNotIn("v3RemoteAnisetteContext = nil", operation)

    def test_real_coalescer_and_explicit_capture_partition_rebind(self):
        actual = generate.extract(read("SideStore/Utils/concurrency/TaskChainCoalescer.swift"), "actor TaskChainCoalescer {")
        self.assertEqual(sha(actual), "482fb5e39a2942d45965163773be92120deac30ff509a8740d6fc9e33c4f7a11")
        method = generate.extract(read("SideStore/Core/Auth/AuthManager.swift"), "public func getAuthenticatedSession()")
        self.assertLess(method.index("let remoteContext = ILoaderRemoteAuthentication.current"), method.index("TaskChainCoalescer.shared.coalesce"))
        self.assertIn('defaultKey + ".remoteAttempt.\\(ObjectIdentifier($0))" } ?? defaultKey', method)
        self.assertIn("ILoaderRemoteAuthentication.$current.withValue(remoteContext)", method)
        self.assertIn("if remoteContext != nil { try Task.checkCancellation() }\n        return session", method)
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
        for name in ["BoundaryDoubles.swift", "OperationBoundaries.swift", "RuntimeTests.swift"]:
            text = (generate.HERE / name).read_text()
            for forbidden in ["URLSession.shared", ".data(for:", "dataTask(", "Process(", "SecItem", "dlopen("]:
                self.assertNotIn(forbidden, text)

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
            self.assertEqual(len(a["production_extracts"]), 35)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sidestore-root", type=Path, default=ROOT)
    parser.add_argument("--sidesign-root", type=Path)
    args, remaining = parser.parse_known_args()
    ROOT = args.sidestore_root
    SIGN = args.sidesign_root or ROOT.parent / "SideSign"
    unittest.main(argv=[__file__] + remaining)
