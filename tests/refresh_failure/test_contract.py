"""Refresh boundary regression tests against maintained production declarations.

The Swift fixture extracts and executes the actual boundary helper, NSError
wrapper, CombinedFailure capture, and wire parser. It does not call a device,
authentication provider, native vendor library, or a network endpoint.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SWIFTC = shutil.which('swiftc')


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


def generate_source(root):
    """Return production boundary/mapper source and exact input paths, no model/doubles.

    Consumers provide CombinedFailure, V3HeadlessPairingFailure, and inert SDK/model
    shells. This lets the end-to-end wire fixture use the same real producer logic.
    """
    paths = {name: root / name for name in [
        'AltStore/AppDelegate.swift', 'SideStore/Core/Operations/PipelineExecutor.swift',
        'SideStore/Core/Operations/OperationStep.swift', 'SideStore/Core/Operations/AppOperation.swift',
        'AltStore/Managing Apps/AppManager.swift', 'SideStore/Core/Operations/Errors/OperationError.swift',
        'Shared/Extensions/NSError+AltStore.swift', 'Shared/Errors/ALTWrappedError.swift',
        'tests/refresh_failure/test_contract.py', 'tests/refresh_failure/boundary_cases.swift',
        'tests/refresh_failure/certificate_cases.swift', 'tests/refresh_failure/boundary_assertions.swift',
        'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift']}
    read = lambda name: paths[name].read_text()
    pipeline = read('SideStore/Core/Operations/PipelineExecutor.swift')
    step_source = read('SideStore/Core/Operations/OperationStep.swift')
    step_cases = step_source[step_source.index('enum PipelineStep:'):step_source.index('    fileprivate static let stepMap:')]
    source = '\nimport CryptoKit\nprotocol OperationStep: Equatable, Hashable {}\n' + step_cases + '}\n'
    source += '\n' + declaration(read('SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift'), 'struct V3RefreshSelectionFailure:')
    for signature in ['func lcSigningHash(', 'func lcPreservationCertificateFacts(', 'enum V3RefreshFailureBoundary:', 'func lcRefreshFailureFacts(', 'func lcSafeSigningCause(', 'func lcStructuredSigningFailure(', 'private final class LCSigningHTTPObservation:', 'func lcPortalSigningRequest<T>']:
        source += '\n' + declaration(pipeline, signature)
    app_operation = read('SideStore/Core/Operations/AppOperation.swift')
    source += '\n' + app_operation[app_operation.index('enum AppOperation:'):app_operation.index('    func logSummary(')]
    source += '\n' + declaration(app_operation, '    var app:') + '\n}\n'
    source += '\n' + declaration(read('AltStore/Managing Apps/AppManager.swift'), '    func getMappedError(')
    source += '\n' + read('SideStore/Core/Operations/Errors/OperationError.swift')
    title_source = read('Shared/Extensions/NSError+AltStore.swift')
    source += '\nextension NSError {\n' + declaration(title_source, '    var localizedFailure:')
    source += '\n' + declaration(title_source, '    func withLocalizedTitle(') + '\n}\n'
    wrapped = read('Shared/Errors/ALTWrappedError.swift')
    source += '\n' + wrapped.replace('@objc(ALTWrappedError)\n', '').replace('@objc ', '')
    source += '\n' + read('tests/refresh_failure/boundary_cases.swift')
    source += '\n' + read('tests/refresh_failure/boundary_assertions.swift')
    app = read('AltStore/AppDelegate.swift')
    source += '\n@MainActor enum FixtureCertificateCommands {\n'
    source += declaration(app, '    enum V3CertificatePortalReadBoundary {') + '\n'
    source += declaration(app, '    static func portalCertificates()') + '\n'
    source += 'static func certificateRow(_ certificate: FixturePortalCertificate, activeSerial: String?) -> [String: Any] { ["active": certificate.serialNumber == activeSerial] }\n}\n'
    source += '\n' + read('tests/refresh_failure/certificate_cases.swift')
    return source, paths


class RefreshFailureContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pipeline = (ROOT / 'SideStore/Core/Operations/PipelineExecutor.swift').read_text()
        cls.refresh = (ROOT / 'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text()
        cls.shared = (ROOT / 'AltStore/AppDelegate.swift').read_text()

    def test_native_instruction_boundaries_preserve_existing_flow(self):
        profile = self.refresh.split('        do {\n            await CellularRefreshManager.shared.turnOffDataIfNeeded()', 1)[1]
        profile = profile.split('        self.setProgress(80)', 1)[0]
        self.assertEqual(profile.count('try await installProvisioningProfiles(p.value.data)'), 1)
        self.assertIn('await CellularRefreshManager.shared.turnOnDataIfNeeded()\n            throw V3RefreshFailureBoundary.provisioningProfileInstallation.preserving(error)', profile)
        self.assertNotIn('retry', profile)
        record = self.refresh.split('        let installedApp: InstalledApp', 1)[1].split('        self.setProgress(100)', 1)[0]
        self.assertEqual(record.count('try self.updateInstalledApp(profiles: profiles, in: dbContext)'), 1)
        self.assertIn('throw V3RefreshFailureBoundary.refreshRecordUpdate.preserving(error)', record)
        self.assertIn('if error is CancellationError { throw error }', self.pipeline)
        self.assertIn('if case .refresh = appOperation, error is CombinedFailure { throw error }', self.pipeline)
        self.assertIn('if case .refresh = appOperation, sourceStep == nil', self.pipeline)
        self.assertIn('sourceStep = V3RefreshFailureBoundary.pipelineStep(step)?.sourceStep.rawValue', self.pipeline)
        self.assertIn('case .fetchProvisioningProfiles: sourceStep = "provisioningProfileFetch"', self.pipeline)
        self.assertIn('(sourceStep == "provisioningProfileFetch" && selection.reason.rawValue.hasPrefix("preservation"))', self.pipeline)

    def test_preservation_certificate_source_is_verified_cache_without_active_fallback(self):
        branch = declaration(self.pipeline, '                if context.isPreservationRefresh {')
        self.assertIn('verifiedSerial: context.verifiedRefreshCertificate?.serial', branch)
        self.assertIn('verifiedDER: context.verifiedRefreshCertificate?.data', branch)
        self.assertNotIn('targetSigningCertificate', branch)
        helper = declaration(self.pipeline, 'func lcPreservationCertificateFacts(')
        self.assertNotIn('targetSigningCertificate', helper)
        self.assertIn('lcSigningHash(serial)', helper)
        source, _ = generate_source(ROOT)
        self.assertIn('import CryptoKit', source)
        self.assertIn(declaration(self.pipeline, 'func lcSigningHash('), source)
        self.assertIn(helper, source)

    def test_five_finite_boundaries_and_no_mutable_last_step(self):
        boundary = declaration(self.pipeline, 'enum V3RefreshFailureBoundary:')
        expected = ['certificateSelection', 'refreshMetadataCache', 'refreshApplication',
                    'provisioningProfileInstallation', 'refreshRecordUpdate']
        source_steps = declaration(self.shared, '    public enum SourceStep:')
        for name in expected:
            self.assertIn('return .' + name, boundary)
            self.assertIn(name, source_steps)
        for forbidden in ['static var', 'UserDefaults', 'print(', 'debugLog(', 'localizedDescription',
                          'reset', 'FileManager', '@TaskLocal']:
            self.assertNotIn(forbidden, boundary)
        self.assertIn('case .provisioningProfileInstallation: return .installation', boundary)
        self.assertIn('case .refreshRecordUpdate: return .persistence', boundary)
        classifier = declaration(self.pipeline, 'func lcRefreshFailureFacts(')
        self.assertIn('guard let operation = error as? OperationError else { return [:] }', classifier)
        for forbidden in ['localizedDescription', 'userInfo', 'String(describing:', 'Mirror(', 'let appName']:
            self.assertNotIn(forbidden, classifier)
        self.assertIn('facts.merge(lcRefreshFailureFacts(error, sourceStep: sourceStep))', self.pipeline)
        self.assertIn('certificateError.domain == "V3CertificateVerification", certificateError.code == 6', classifier)
        self.assertIn('return ["refresh_failure_kind": "certificateVerificationUnavailable"]', classifier)
        self.assertIn('facts["local_precondition"] = reason', classifier)

    def test_existing_markers_win_and_no_new_payload_is_serialized(self):
        wrapper = declaration(self.pipeline, 'func lcStructuredSigningFailure(')
        self.assertIn('if let prior = native.userInfo[key] as? String { info[key] = prior }', wrapper)
        self.assertIn('CombinedFailure.validatedSigningContext(context)', wrapper)
        mapping = (ROOT / 'Shared/Extensions/NSError+AltStore.swift').read_text()
        method = declaration(mapping, '    func withLocalizedTitle(')
        self.assertIn('var userInfo = self.userInfo', method)
        self.assertIn('ALTWrappedError(error: self, userInfo: userInfo)', method)
        native = (ROOT / 'Shared/Errors/ALTWrappedError.swift').read_text()
        self.assertIn('super.init(domain: error.domain, code: error.code, userInfo: userInfo)', native)
        mapper = declaration((ROOT / 'AltStore/Managing Apps/AppManager.swift').read_text(),
                             '    func getMappedError(')
        self.assertIn('if case .refresh = operation, let failure = error as? CombinedFailure', mapper)
        self.assertLess(mapper.index('return failure'), mapper.index('var appName: String!'))

    def test_composable_source_extracts_actual_certificate_requests(self):
        source, inputs = generate_source(ROOT)
        self.assertNotIn('public struct CombinedFailure:', source)
        self.assertNotIn('enum V3HeadlessPairingFailure {', source)
        self.assertNotIn('@main', source)
        self.assertIn('func refreshBoundaryFixtureCases()', source)
        self.assertIn('func certificatePortalBoundaryFixtureCases()', source)
        self.assertTrue(all(path.is_file() for path in inputs.values()))
        portal = declaration(self.shared, '    static func portalCertificates()')
        self.assertIn(portal, source)
        for stage, step, call in [('authentication', 'authenticate', 'getAuthenticatedSession()'),
                                  ('authentication', 'accountLookup', 'getAuthenticatedTeam()'),
                                  ('signing', 'fetchCertificate', 'fetchCertificates(team: team)')]:
            self.assertIn('perform(stage: .' + stage + ', step: .' + step + ')', portal)
            self.assertEqual(portal.count(call), 1)
        helper = declaration(self.shared, '    enum V3CertificatePortalReadBoundary {')
        self.assertIn('catch let failure as CombinedFailure { throw failure }', helper)
        self.assertIn('catch is CancellationError { throw CancellationError() }', helper)
        self.assertIn('stage: stage.rawValue, sourceStep: step.rawValue', helper)

    def test_actual_swift_boundary_capture_and_wire_roundtrip(self):
        if SWIFTC is None:
            if os.environ.get('REQUIRE_SWIFT_REFRESH_FAILURE_TESTS') == '1':
                self.fail('Swift compiler required; refresh failure runtime fixture NOT RUN')
            self.skipTest('Swift compiler unavailable; refresh failure runtime fixture NOT RUN')
        boundaries, _ = generate_source(ROOT)
        source = common(self.shared) + boundaries
        source += '\n' + declaration(self.shared, 'enum V3HeadlessPairingFailure {')
        source += '\n' + (HERE / 'pipeline_harness.swift').read_text()
        source += '\n@main struct RunRefreshFailureFixture { static func main() async throws { try RefreshFailureBoundaryHarness.main(); _ = try await certificatePortalBoundaryFixtureCases() } }\n'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            swift = path / 'RefreshFailure.swift'
            swift.write_text(source)
            binary = path / 'refresh-failure'
            compiled = subprocess.run([SWIFTC, '-parse-as-library', str(swift), '-o', str(binary)],
                                      capture_output=True, text=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('REFRESH_FAILURE_BOUNDARY_PASS', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
