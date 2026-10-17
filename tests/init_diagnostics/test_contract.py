"""Focused P0 diagnostic tests against maintained production declarations.

Source checks are not substitutes for Swift execution or a physical-device run.
No production files are generated, patched, or imported from historical templates.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
LOCAL_ROOT = HERE.parents[1]
SIDE_SOURCE = os.environ.get('SIDE_STORE_TEST_SOURCE')
LIVE_SOURCE = os.environ.get('MAINTAINED_LIVE_CONTAINER_TEST_SOURCE') or os.environ.get('LIVE_CONTAINER_TEST_SOURCE')
ROOT = Path(SIDE_SOURCE or LIVE_SOURCE) if SIDE_SOURCE or LIVE_SOURCE else LOCAL_ROOT
peer_source = os.environ.get('INIT_DIAGNOSTICS_PEER_ROOT') or (LIVE_SOURCE if (ROOT / 'AltStore').exists() else SIDE_SOURCE)
PEER = Path(peer_source) if peer_source else None
producer_source = os.environ.get('INIT_DIAGNOSTICS_PRODUCER_ROOT') or os.environ.get('ANISETTE_KIT_TEST_SOURCE')
PRODUCER = Path(producer_source) if producer_source else None
SWIFTC = shutil.which('swiftc')


def owner(root):
    return root / ('AltStore/AppDelegate.swift' if (root / 'AltStore').exists() else 'SideStoreSupport/SideStore.swift')


def declaration(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def common(source):
    start = source.index('public struct CombinedRefreshTargetPlan:')
    last = declaration(source, 'public enum V3DiagnosticPresentation {')
    return 'import Foundation\nimport CoreFoundation\n' + source[start:source.index(last, start) + len(last)]


class InitializerDiagnosticContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = owner(ROOT).read_text()

    def test_shared_capture_validation_and_copy_contracts_match(self):
        if PEER is None:
            self.skipTest('Set INIT_DIAGNOSTICS_PEER_ROOT to the other maintained checkout')
        peer = owner(PEER).read_text()
        for signature in ['struct V3AnisetteNativeEvidence {',
                          '    public static func validatedSigningContext(',
                          'struct V3AccountOperationError:',
                          'enum V3AuthFailureDiagnosticsPolicy {']:
            self.assertEqual(declaration(self.source, signature), declaration(peer, signature))
        lc = ROOT if (ROOT / 'SideStoreSupport').exists() else PEER
        host = (lc / 'LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
        self.assertIn('import SideStoreSupport', host)
        self.assertEqual(declaration(self.source, 'enum V3AuthFailureDiagnosticsPolicy {'),
                         declaration(host, 'enum V3AuthFailureDiagnosticsPolicy {'))
        self.assertEqual(Path(__file__).read_bytes(), (ROOT / 'tests/init_diagnostics/test_contract.py').read_bytes())
        for name in ['pipeline_harness.swift', 'host_harness.swift', 'test_contract.py', 'README.md', 'native_fixture.cpp']:
            self.assertEqual((ROOT / 'tests/init_diagnostics' / name).read_bytes(),
                             (PEER / 'tests/init_diagnostics' / name).read_bytes())

    def test_bounded_primary_only_contract_and_no_recovery_mutation(self):
        native = declaration(self.source, 'struct V3AnisetteNativeEvidence {')
        base = declaration(native, '    private static func captureBase(')
        self.assertLess(base.index('guard code == -2'), base.index('ConstructorFailure(description:'))
        self.assertLess(base.index('nativeDescriptionWithoutTrace(description)'), base.index('ConstructorFailure(description:'))
        self.assertIn('tokens.count == 6', native)
        self.assertIn('String(value) == text', native)
        self.assertIn('maximum: 255', native)
        self.assertIn('maximum: 65535', native)
        self.assertIn('fields["native_subcode"] == "unknown"', native)
        validate = declaration(self.source, '    public static func validatedSigningContext(')
        self.assertIn('fields.count <= 20', validate)
        self.assertIn('ConstructorFailure.validatesContext(fields)', validate)
        attempt = declaration(self.source, 'struct V3AnisetteAttemptContext {')
        self.assertNotIn('constructorFailure', attempt)
        self.assertNotIn('native_init_', attempt)
        constructor = declaration(native, '    struct ConstructorFailure {')
        for forbidden in ['UserDefaults', 'FileManager', 'print(', 'uc_reg_read', 'removeItem', 'reset', 'password']:
            self.assertNotIn(forbidden, constructor)
        self.assertIn('signingContext.merge(constructor.diagnosticFields)',
                      declaration(self.source, 'struct V3AccountOperationError:'))
        self.assertIn('"native_init_engine"', declaration(self.source, 'enum V3AuthFailureDiagnosticsPolicy {'))

    def produced(self):
        if PRODUCER is None:
            self.skipTest('Set INIT_DIAGNOSTICS_PRODUCER_ROOT to the reviewed AnisetteKit checkout')
        compiler = shutil.which('c++')
        if compiler is None:
            self.skipTest('C++ compiler unavailable; real producer fixture NOT RUN')
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'producer'
            built = subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I', str(PRODUCER / 'Native/Loader'), str(HERE / 'native_fixture.cpp'),
                '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = result.stdout.splitlines()
        self.assertEqual(len(rows), 21)
        self.assertEqual(rows[0], 'Library constructor execution failed [v1;kind=dt_init;reason=engine_error;engine=13;library=0;initializer=0]')
        self.assertEqual(rows[-1], 'Library constructor execution failed [v1;kind=unknown;reason=unknown;engine=-1;library=-1;initializer=-1]')
        self.assertTrue(all(len(row.encode()) <= 256 for row in rows))
        return result.stdout

    def test_real_native_producer_fixture(self):
        self.produced()

    def execute(self, disabled):
        if PEER is None:
            self.skipTest('Set INIT_DIAGNOSTICS_PEER_ROOT to the other maintained checkout')
        if SWIFTC is None:
            self.skipTest('Swift compiler unavailable; native Swift parser/wire/render execution NOT RUN')
        ss = ROOT if (ROOT / 'AltStore').exists() else PEER
        lc = ROOT if (ROOT / 'SideStoreSupport').exists() else PEER
        app = owner(ss).read_text()
        classifier = app[app.index('enum V3AuthFailureKind:'):app.index('// MARK: - Provisioning failure guidance')]
        source = common(self.source) + '\n' + classifier + '\n' + declaration(self.source, 'enum V3AuthFailureDiagnosticsPolicy {')
        source += '\n' + (ROOT / 'tests/adi_consumption/external_error_doubles.swift').read_text()
        if disabled:
            source = source.replace('public static let temporaryAnisetteTraceEnabled = true',
                                    'public static let temporaryAnisetteTraceEnabled = false')
        source += '\n' + (HERE / 'pipeline_harness.swift').read_text()
        produced = self.produced()
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            (d / 'Pipeline.swift').write_text(source)
            (d / 'native.txt').write_text(produced)
            self.compile(['-parse-as-library', str(d / 'Pipeline.swift'), '-o', str(d / 'pipeline')])
            run = subprocess.run([str(d / 'pipeline'), 'disabled' if disabled else 'enabled', str(d / 'failure.txt'), str(d / 'native.txt')],
                                 capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('INITIALIZER_CONSUMER_PIPELINE_PASS', run.stdout)
            # Read the service-produced binary plist with an independently compiled
            # host module and the real importing UI renderer, with no type doubles.
            support = common(owner(lc).read_text())
            if disabled:
                support = support.replace('public static let temporaryAnisetteTraceEnabled = true',
                                          'public static let temporaryAnisetteTraceEnabled = false')
            (d / 'Support.swift').write_text(support)
            library = d / ('libSideStoreSupport.dylib' if sys.platform == 'darwin' else 'libSideStoreSupport.so')
            self.compile(['-emit-library', '-emit-module', '-module-name', 'SideStoreSupport', str(d / 'Support.swift'),
                          '-emit-module-path', str(d / 'SideStoreSupport.swiftmodule'), '-o', str(library)])
            host = (lc / 'LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
            (d / 'Host.swift').write_text('import Foundation\nimport SideStoreSupport\n' +
                declaration(host, 'enum V3AuthFailureDiagnosticsPolicy {') + '\n' +
                (HERE / 'host_harness.swift').read_text())
            self.compile(['-I', str(d), '-L', str(d), '-lSideStoreSupport', str(d / 'Host.swift'), '-o', str(d / 'host')])
            env = dict(os.environ)
            env['DYLD_LIBRARY_PATH' if sys.platform == 'darwin' else 'LD_LIBRARY_PATH'] = str(d)
            run = subprocess.run([str(d / 'host'), str(d / 'failure.txt')], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('INITIALIZER_HOST_ROUNDTRIP_PASS', run.stdout)

    def compile(self, arguments):
        run = subprocess.run([SWIFTC, *arguments], capture_output=True, text=True, timeout=180)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_actual_swift_parser_service_wire_and_host_copy(self):
        self.execute(False)

    def test_trace_disabled_preserves_constructor_evidence(self):
        self.execute(True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
