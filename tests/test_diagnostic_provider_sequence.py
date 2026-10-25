"""Execute production Foundation policy; distinguish missing Swift from success."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
POLICY = ROOT / "SideStore/Core/Anisette/V3DiagnosticProviderSequence.swift"
SERVICE = ROOT / "AltStore/AppDelegate.swift"
OPERATION = ROOT / "SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift"


class ProviderSequenceTests(unittest.TestCase):
    def test_service_integration(self):
        service = SERVICE.read_text()
        operation = OPERATION.read_text()
        self.assertIn('offered.selecting(raw.components(separatedBy: ",")) != nil', service)
        self.assertIn('? ["remoteMac"] : ["remoteMac", "remoteServer"]', service)
        self.assertIn('sequence.previousAttemptStopped(attempt,', operation)
        self.assertIn('credentialsCommitted: identityStamp != AuthManager.shared.v3IdentityStamp', operation)
        self.assertIn('defer { group.cancelAll() }', operation)
        self.assertIn('await clock?.beginUserInput()', service)
        self.assertIn('appleStarted || provider != .remoteMac ? .unknown : .timedOut', operation)
        self.assertIn('if challengeSeen { sequence.needsUser(attempt) }', operation)
        self.assertNotIn('UserDefaults.standard.useOnDeviceAnisette =', operation)
        self.assertIn('V3DiagnosticProviderRoute.$current.withValue(provider)', operation)
        self.assertIn('V3DiagnosticProviderRoute.$current.withValue(self.v3DiagnosticProvider)', operation)
        self.assertIn('v3BeginIdentityTransition(ifCurrent: captured)', operation)
        self.assertIn('v3DiagnosticProvider != .remoteServer || !UserDefaults.standard.useOnDeviceAnisette', operation)
        self.assertIn('func beginTransition(ifCurrent capturedStamp: String) -> Bool', service)
        self.assertIn('v3InstallSessionIfCurrent(session, capturedStamp: committedStamp)', operation)
        fixture = (ROOT / "tests/provider_sequence/noncooperative.swift").read_text()
        self.assertNotIn("Task.sleep", fixture)
        self.assertIn("await probe.waitUntilBlocked()", fixture)
        self.assertIn("await probe.waitUntilPending()", fixture)
        observed = fixture.index("} catch {")
        self.assertLess(fixture.index("group.cancelAll()", observed),
                        fixture.index("await probe.markPending()", observed))
        self.assertEqual(fixture.count("precondition("), 4)

    def test_production_policy(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("Swift compiler required; policy execution not performed")
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / "provider-sequence"
            subprocess.run([swift, str(POLICY), str(ROOT / "tests/provider_sequence/main.swift"),
                            "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], check=True, text=True, capture_output=True)
            self.assertIn("checks passed", result.stdout)
            print(result.stdout.strip())

    def test_stale_identity_cannot_reserve_commit(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("Swift compiler required; identity guard execution not performed")
        source = SERVICE.read_text()
        start = source.index("final class V3AuthIdentityStampState:")
        end = source.index("// V3_CRASH_REASON_LOG_PRIVACY_V1", start)
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            policy = directory / "identity.swift"
            policy.write_text("import Foundation\n" + source[start:end])
            main = directory / "main.swift"
            main.write_text("""import Foundation
let state = V3AuthIdentityStampState()
let stale = state.snapshot.stamp
state.advanceGeneration()
precondition(!state.beginTransition(ifCurrent: stale))
let fresh = state.snapshot.stamp
precondition(state.beginTransition(ifCurrent: fresh))
precondition(!state.snapshot.stable)
precondition(!state.beginTransition(ifCurrent: fresh))
let committed = state.completeTransitionReturningStamp()
precondition(state.snapshot.stable)
precondition(!state.beginTransition(ifCurrent: fresh))
var installed = false
state.advanceGeneration()
precondition(!state.runIfCurrent(committed) { installed = true })
precondition(!installed)
print("Identity reservation: 8 checks passed")
""")
            binary = directory / "identity"
            subprocess.run([swift, str(policy), str(main), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_noncooperative_attempt_does_not_rotate(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("Swift compiler required; cancellation execution not performed")
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / "noncooperative"
            subprocess.run([swift, "-parse-as-library", str(POLICY),
                            str(ROOT / "tests/provider_sequence/noncooperative.swift"),
                            "-o", str(binary)], check=True)
            # Exercise scheduler ordering repeatedly without recompiling. The
            # prior SIGTRAP lacked stderr; scheduling was a suspected cause,
            # not a conclusively diagnosed crash.
            for iteration in range(10):
                try:
                    result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
                except subprocess.TimeoutExpired as error:
                    # Keep scheduler deadlocks bounded and make captured diagnostics
                    # visible without flooding the CI log with an entire crash dump.
                    def tail(value):
                        if isinstance(value, bytes):
                            value = value.decode(errors="replace")
                        return (value or "")[-8000:]
                    self.fail(f"Cancellation fixture iteration {iteration + 1} exceeded 10s watchdog\nstdout:\n" +
                              tail(error.stdout) + "\nstderr:\n" + tail(error.stderr))
                self.assertEqual(result.returncode, 0,
                                 f"Cancellation fixture iteration {iteration + 1} exit {result.returncode}\n"
                                 f"stdout:\n{result.stdout[-8000:]}\nstderr:\n{result.stderr[-8000:]}")
                self.assertIn("4 checks passed", result.stdout)




if __name__ == "__main__":
    unittest.main()
