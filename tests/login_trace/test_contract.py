"""Finite login diagnostics: source checks plus actual Swift parser when available."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
PEER = Path(os.environ['LOGIN_TRACE_PEER_ROOT']) if os.environ.get('LOGIN_TRACE_PEER_ROOT') else None
PRODUCER = Path(os.environ['LOGIN_TRACE_PRODUCER_ROOT']) if os.environ.get('LOGIN_TRACE_PRODUCER_ROOT') else None

def owner(root):
    return root / ('AltStore/AppDelegate.swift' if (root/'AltStore').exists() else 'SideStoreSupport/SideStore.swift')

def declaration(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

class LoginTraceContract(unittest.TestCase):
    def test_parser_render_and_validator_match(self):
        if PEER is None: self.skipTest('Set LOGIN_TRACE_PEER_ROOT')
        a, b = owner(ROOT).read_text(), owner(PEER).read_text()
        for signature in ['public struct V3LoginDiagnosticSnapshot {', 'public struct V3TemporaryAnisetteTrace:',
                          '    public static func validatedSigningContext(', 'enum V3AuthFailureDiagnosticsPolicy {']:
            self.assertEqual(declaration(a, signature), declaration(b, signature))
        lc = ROOT if (ROOT/'SideStoreSupport').exists() else PEER
        ui = (lc/'LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
        self.assertEqual(declaration(a, 'enum V3AuthFailureDiagnosticsPolicy {'), declaration(ui, 'enum V3AuthFailureDiagnosticsPolicy {'))
        self.assertIn('V3LoginDiagnosticSnapshot.init(encoded:)', declaration(ui, 'enum V3AuthFailureDiagnosticsPolicy {'))

    def test_finite_parser_and_existing_limits(self):
        source = owner(ROOT).read_text()
        parser = declaration(source, 'public struct V3LoginDiagnosticSnapshot {')
        for token in ['maximumBytes = 2048', 'maximumEvents = 128', 'maximumWireBytes = 4096',
                      'columns.count == 7', 'String($0.1) == String($0.0)', '(0...56).contains(values[0])',
                      'context.count < 20', 'rows.dropFirst()', 'login_trace_v1']:
            self.assertIn(token, parser)
        for forbidden in ['@TaskLocal', 'UserDefaults', 'FileManager', 'print(', 'localizedDescription', 'userInfo']:
            self.assertNotIn(forbidden, parser)
        wire = declaration(source, '    public var wire:')
        self.assertIn('V3LoginDiagnosticSnapshot.boundingWire(result)', wire)
        self.assertIn('V3TemporaryADIConsumption.boundingWire(result)', wire)
        trace = declaration(source, 'public struct V3TemporaryAnisetteTrace:')
        for token in ['native.start.ok', 'native.start.failed', 'native.end.ok', 'native.end.failed', 'native.output.not_checked']:
            self.assertIn(token, trace)

    def test_producer_stage_range_and_generated_correlation(self):
        if PRODUCER is None: self.skipTest('Set LOGIN_TRACE_PRODUCER_ROOT')
        source = (PRODUCER/'Sources/LoginDiagnosticTrace.swift').read_text()
        enum = declaration(source, 'public enum LoginDiagnosticStage:')
        names = [word.strip() for line in enum.splitlines() if line.strip().startswith('case ')
                 for word in line.strip().removeprefix('case ').split(',')]
        self.assertEqual(len(names), 57)
        self.assertEqual(names[54], 'nativeCall')
        self.assertIn('UUID().uuidString', source)
        self.assertIn('prefix(12)', source)
        self.assertIn('login_trace_v1', source)

    def test_operation_ownership_and_fail_closed_paths(self):
        ss = ROOT if (ROOT/'AltStore').exists() else PEER
        if ss is None: self.skipTest('Set LOGIN_TRACE_PEER_ROOT')
        operation = (ss/'SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift').read_text()
        for token in ['LoginDiagnosticTrace.$current.withValue(loginDiagnosticTrace)', '.preconditions', '.credentialRead',
                      '.credentialRoute', '.uiCredentials', '.anisetteFetch', '.appleAuthentication',
                      '.credentialCommit', '.sessionCommit', '.accountSave', '.accountFinalize', '.cleanup', '.provisioning',
                      'candidate.matchesVerifiedIdentity', 'V3AuthReadStampPolicy.mayReturn',
                      'v3CachedSessionMatchesCurrentRoute(authResult.session)', 'V3TwoFactorRetryPolicy.shouldReuseCredentialsForCodeRetry']:
            self.assertIn(token, operation)
        for line in operation.splitlines():
            if 'debugLog(' in line or 'verboseLog(' in line:
                self.assertNotIn('\\(error', line)
                self.assertNotIn('\\(team.', line)
                self.assertNotIn('\\(machineName)', line)
        for helper in ['func v3LoginStage<T>', 'func v3LoginStageSync<T>']:
            self.assertIn('throw error', declaration(operation, helper))
        recovery = (ss/'SideStore/Core/Anisette/OnDeviceAnisetteManager.swift').read_text()
        self.assertIn('guard LCAnisetteRecoveryPolicy.automaticRecoveryEnabled else', recovery)
        self.assertIn('skip(.recoveryCommit, reason: .disabled)', recovery)
        self.assertIn('recoveryLegacyRead', recovery)
        app = owner(ss).read_text()
        self.assertIn('LoginDiagnosticTrace.$current.withValue(trace)', app)
        for line in app.splitlines():
            if '[V3_AUTH]' in line and 'debugLog(' in line:
                self.assertNotIn('session=', line)
                self.assertNotIn('failure.correlationID', line)
                self.assertNotIn('\\(error', line)
        self.assertIn('V3LoginDiagnosticSnapshot.attaching(session.loginDiagnosticTrace.snapshot(), to: failure)', app)

    def test_timeout_adds_diagnostics_without_changing_terminal_policy(self):
        ss = ROOT if (ROOT/'AltStore').exists() else PEER
        if ss is None: self.skipTest('Set LOGIN_TRACE_PEER_ROOT')
        app = owner(ss).read_text()
        policy = declaration(app, 'enum V3AuthTimeoutDiagnosticPolicy {')
        self.assertIn('supplied["failure"] == nil', policy)
        for key in ['state', 'authenticated', 'resumable', 'message']:
            self.assertNotIn('result["' + key + '"] =', policy)
        start = app.index('    func expire(id: String) {')
        expiry = declaration(app[start:], '    func expire(id: String) {')
        self.assertIn('if let failure = session.rejectedPortalSessionFailure', expiry)
        self.assertIn('code: .timedOut, id: id', expiry)
        self.assertIn('stage: authenticated ? .provisioning : .authentication', expiry)
        self.assertIn('session.loginDiagnosticTrace.begin(.login).finish(.failed, reason: .unavailable)', expiry)
        self.assertLess(expiry.index('session.loginDiagnosticTrace.begin'), expiry.index('finish(id: id, response: response)'))

    def test_timeout_host_retention_is_diagnostic_only(self):
        lc = ROOT if (ROOT/'SideStoreSupport').exists() else PEER
        if lc is None: self.skipTest('Set LOGIN_TRACE_PEER_ROOT')
        host = (lc/'LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
        policy = declaration(host, 'enum V3AuthTimeoutDiagnosticRetentionPolicy {')
        for token in ['maximumWireBytes', 'CombinedFailure.decode(supplied, expectedID: expectedID)',
                      'decoded.operation == "signIn"', 'V3LoginDiagnosticSnapshot(encoded: raw)']:
            self.assertIn(token, policy)
        store = declaration(host, 'final class V3AuthStore:')
        self.assertEqual(store.count('timeoutDiagnosticFailure = nil'), 3)
        self.assertIn('V3AuthTimeoutDiagnosticRetentionPolicy.shouldClearOnSessionChange(', store)
        self.assertIn('timeoutDiagnosticFailure = V3AuthTimeoutDiagnosticRetentionPolicy.failure(reply: reply, expectedID: session)', store)
        self.assertIn('hasFailure: auth.terminalDiagnosticFailure != nil', host)
        self.assertIn('let failure = auth.terminalDiagnosticFailure', host)
        for signature in ['    private var terminalFailureKind:', '    private var terminalFailureRetryable:',
                          '    var terminalFailureAction:', '    var terminalFailureGuidance:']:
            self.assertNotIn('timeoutDiagnostic', declaration(store, signature))

    def test_real_swift_timeout_host_retention_and_copy(self):
        compiler = shutil.which('swiftc')
        if compiler is None: self.skipTest('Swift compiler unavailable; real host timeout consumer NOT RUN')
        lc = ROOT if (ROOT/'SideStoreSupport').exists() else PEER
        if lc is None: self.fail('Set LOGIN_TRACE_PEER_ROOT')
        support = owner(lc).read_text()
        start = support.index('public struct CombinedRefreshTargetPlan:')
        last = declaration(support, 'public enum V3DiagnosticPresentation {')
        support = 'import Foundation\nimport CoreFoundation\n' + support[start:support.index(last, start) + len(last)]
        host = (lc/'LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
        source = 'import Foundation\nimport SideStoreSupport\n'
        source += declaration(host, 'enum V3AuthTimeoutDiagnosticRetentionPolicy {') + '\n'
        source += declaration(host, 'enum V3AuthFailureDiagnosticsPolicy {') + '\n'
        source += (Path(__file__).parent/'timeout_host_harness.swift').read_text()
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp); (p/'Support.swift').write_text(support); (p/'Host.swift').write_text(source)
            library = p/('libSideStoreSupport.dylib' if sys.platform == 'darwin' else 'libSideStoreSupport.so')
            for args in [
                ['-emit-library', '-emit-module', '-module-name', 'SideStoreSupport', str(p/'Support.swift'),
                 '-emit-module-path', str(p/'SideStoreSupport.swiftmodule'), '-o', str(library)],
                ['-I', str(p), '-L', str(p), '-lSideStoreSupport', str(p/'Host.swift'), '-o', str(p/'host')]]:
                built = subprocess.run([compiler, *args], capture_output=True, text=True, timeout=180)
                self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            env = dict(os.environ); env['DYLD_LIBRARY_PATH' if sys.platform == 'darwin' else 'LD_LIBRARY_PATH'] = str(p)
            run = subprocess.run([str(p/'host')], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('LOGIN_TIMEOUT_HOST_CONTRACT_PASS', run.stdout)

    def test_real_swift_parser_and_wire(self):
        compiler = shutil.which('swiftc')
        if compiler is None: self.skipTest('Swift compiler unavailable; real parser/wire execution NOT RUN')
        source = 'import Foundation\n' + declaration(owner(ROOT).read_text(), 'public struct V3LoginDiagnosticSnapshot {')
        ss = ROOT if (ROOT/'AltStore').exists() else PEER
        if ss is None: self.fail('Set LOGIN_TRACE_PEER_ROOT for actual timeout contract')
        source += '\n' + declaration(owner(ss).read_text(), 'enum V3AuthSessionExpiryPolicy {')
        source += '\n' + declaration(owner(ss).read_text(), 'enum V3AuthTimeoutDiagnosticPolicy {')
        source += '\n' + (Path(__file__).parent/'host_harness.swift').read_text()
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp); (p/'main.swift').write_text(source)
            built = subprocess.run([compiler, str(p/'main.swift'), '-o', str(p/'test')], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(p/'test')], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('LOGIN_TRACE_HOST_CONTRACT_PASS', result.stdout)

if __name__ == '__main__': unittest.main()
