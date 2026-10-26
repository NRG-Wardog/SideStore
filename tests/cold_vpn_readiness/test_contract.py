"""Owned pre-mutation readiness: extracted production wait with inert probe doubles."""
import os
import platform
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'SideStore/Core/Operations/PipelineRunner.swift'

class ColdVPNReadinessTests(unittest.TestCase):
    def test_owned_probe_precedes_every_mutation_boundary(self):
        s = RUNNER.read_text()
        b = s.split('// COMBINED_COREDEVICE_PIPELINE_BATCH_V1:', 1)[1].split('func performOperation(', 1)[0]
        self.assertLess(b.index('await transportCore.beginTransportBatch()'), b.index('V3OwnedRefreshReadinessWait.run('))
        self.assertLess(b.index('V3OwnedRefreshReadinessWait.run('), b.index('group.progress.totalUnitCount'))
        self.assertLess(b.index('V3OwnedRefreshReadinessWait.run('), b.index('PreflightChecksOperation('))
        self.assertIn('await transportCore.ownedNetworkReadinessProbe(withNetworkCheck: true)', b)
        self.assertNotIn('isMinimuxerReady()', b)
        self.assertEqual(b.count('await transportCore.endTransportBatch()'), 2)
        self.assertIn('try V3RemoteRequestLeases.admitted?.check()', b)
        self.assertIn('ObjectIdentifier(minimuxer.core) == transportCoreIdentity', b)
        self.assertIn('if !CellularRefreshManager.shared.isEnabled', b)
        self.assertIn('if initialMode == .localVPN {', b)
        remote = b.split('// Remote and unconfigured routes retain', 1)[1].split('try checkReadinessOwnership()', 1)[0]
        self.assertIn('await transportCore.isReady(', remote)
        self.assertNotIn('V3OwnedRefreshReadinessWait.run', remote)
        self.assertNotIn('ownedNetworkReadinessProbe', remote)
        self.assertEqual(b.count('await transportCore.getConnectionMode() == initialMode'), 2)
        self.assertNotIn('applicationState', b)
        self.assertNotIn('.restart(', b)
        self.assertNotIn('performPipeline(', b)
        normal = b.split('taskGroup.addTask {', 1)[1].split('try await self.performOperation', 1)[0]
        self.assertIn('readinessLifetime.check()', normal)
        self.assertIn('V3RemoteRequestLeases.admitted?.check()', normal)
        self.assertIn('ObjectIdentifier(minimuxer.core)', normal)
        host = b.split('for operation in hostOperations {', 1)[1]
        self.assertLess(host.index('checkReadinessOwnership()'), host.index('performOperation('))

    def test_expiry_and_diagnostics_are_finite_and_owned(self):
        s = RUNNER.read_text()
        expiry = s.split('beginBackgroundTask(withName:', 1)[1].split('return taskID', 1)[0]
        self.assertIn('readinessLifetime.expire()', expiry)
        self.assertIn('readinessLifetime.claimEnd()', expiry)
        self.assertIn('backgroundTaskID != .invalid, readinessLifetime.claimEnd()', s)
        helper = s.split('// V3_OWNED_REFRESH_READINESS_WAIT_V1:', 1)[1].split('// V3_OWNED_REFRESH_READINESS_WAIT_END', 1)[0]
        self.assertNotIn('localizedDescription', helper)
        self.assertNotIn('Task.detached', helper)
        self.assertNotIn('ContinuousClock', helper)
        self.assertIn('ProcessInfo.processInfo.systemUptime', helper)
        self.assertIn('case .success(false):', helper)
        self.assertIn('guard let reason = observation.transient', helper)

    def test_refresh_admission_wiring_and_no_post_injection_fence(self):
        runner = RUNNER.read_text()
        executor = (ROOT / 'SideStore/Core/Operations/PipelineExecutor.swift').read_text()
        refresh = (ROOT / 'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text()
        self.assertEqual(runner.count('refreshAdmission: checkReadinessOwnership'), 2)
        self.assertEqual(runner.count('refreshAdmission: refreshAdmission'), 2)
        step = executor.split('private func executeStep(', 1)[1]
        self.assertLess(step.index('await headlessHandler.recordPipelinePhase'), step.index('try refreshAdmission?()'))
        self.assertLess(step.index('try refreshAdmission?()'), step.index('switch step'))
        self.assertIn('if case .refresh = appOperation { step.refreshAdmission = refreshAdmission }', step)
        self.assertEqual(refresh.count('try refreshAdmission?()'), 1)
        self.assertLess(refresh.index('turnOffDataIfNeeded()'), refresh.index('try refreshAdmission?()'))
        self.assertLess(refresh.index('try refreshAdmission?()'), refresh.index('installProvisioningProfiles(p.value.data)'))
        self.assertNotIn('refreshAdmission', refresh.split('installProvisioningProfiles(p.value.data)', 1)[1])
        local = runner.split('if initialMode == .localVPN {', 1)[1].split('} else {', 1)[0]
        self.assertEqual(local.count('await transportCore.isReady('), 1)
        self.assertLess(local.index('V3OwnedRefreshReadinessWait.run'), local.index('await transportCore.isReady('))
        native = local.split('let nativeResult =', 1)[1]
        self.assertIn('try checkReadinessOwnership()', native)
        self.assertNotIn('deadline', native)

    def test_native_production_wait_and_expiry(self):
        compiler = shutil.which('swiftc')
        if not compiler:
            if os.environ.get('REQUIRE_SWIFT_COLD_VPN_TESTS') == '1':
                self.fail('Native Swift compiler required')
            self.skipTest('Swift unavailable locally; extracted production runtime required in CI')
        s = RUNNER.read_text()
        production = s.split('final class V3RefreshReadinessLifetime:', 1)[1].split('// V3_OWNED_REFRESH_READINESS_WAIT_END', 1)[0]
        source = '''import Foundation
// Inert boundary types. The wait/lifetime below are unmodified production source.
enum OperationError: Error, Equatable { case timedOut; case minimuxerNotStarted(reason: String) }
enum MinimuxerError: Error, Equatable { case waiting; case terminal }
enum MinimuxerOwnedReadinessTransient: String { case wifiPending, vpnInterfacePending, peerAddressPending, peerProbePending }
struct MinimuxerOwnedReadinessObservation {
 let result: Result<Bool, MinimuxerError>
 let transient: MinimuxerOwnedReadinessTransient?
}
final class V3RefreshReadinessLifetime:''' + production
        # Extract the actual executor admission, native one-shot, and profile
        # injection blocks. Boundary doubles only replace UIKit/CoreData/network.
        executor = (ROOT / 'SideStore/Core/Operations/PipelineExecutor.swift').read_text()
        phase = executor.split('// V3_PIPELINE_PHASE_REPORTING_V1:', 1)[1]
        phase = phase[phase.index('        if let headlessHandler'):phase.index('        var result: Any?')]
        native = s.split('                    let nativeResult =', 1)[1].split('                } else {', 1)[0]
        native = 'let nativeResult =' + native
        refresh = (ROOT / 'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text()
        injection = refresh.split('        do {\n            await CellularRefreshManager.shared.turnOffDataIfNeeded()', 1)[1]
        injection = 'do {\n await CellularRefreshManager.shared.turnOffDataIfNeeded()' + injection.split('    private func updateInstalledApp(', 1)[0].rsplit('    }', 1)[0]
        source += (ROOT / 'tests/cold_vpn_readiness/boundary_doubles.swift').read_text()
        source += '\nfunc extractedPhase(context: PhaseContext, downloadingApp: DownloadingApp, step: Int, appOperation: FakeOperation, refreshAdmission: (() throws -> Void)?) async throws {\n' + phase + '\n}\n'
        source += '\nfunc extractedNative(transportCore: NativeCore, checkReadinessOwnership: () throws -> Void) async throws {\n' + native + '\n}\n'
        source += '\nextension InjectionHarness { func run(profiles: [String: Profile], refreshAdmission: (() throws -> Void)?) async throws -> InstalledApp { let appBundle = 0\n' + injection + '\n} }\n'
        production_source = source
        source += (ROOT / 'tests/cold_vpn_readiness/runtime_cases.swift').read_text()
        with tempfile.TemporaryDirectory(prefix='cold-vpn-') as tmp:
            p = Path(tmp).resolve()
            (p/'production.swift').write_text(production_source)
            if platform.system() == 'Darwin':
                project = (ROOT / 'AltStore.xcodeproj/project.pbxproj').read_text()
                targets = set(re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);', project))
                self.assertEqual(targets, {'15.0'}, 'Update reviewed deployment qualification with target changes')
                sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
                arch = platform.machine()
                self.assertIn(arch, ('arm64', 'x86_64'))
                subprocess.run([compiler, '-typecheck', '-target', arch + '-apple-ios15.0-simulator',
                                '-sdk', sdk, str(p/'production.swift')], check=True)
            elif os.environ.get('REQUIRE_SWIFT_COLD_VPN_TESTS') == '1':
                self.fail('Required iOS15 SDK typecheck needs macOS/Xcode')
            (p/'main.swift').write_text(source)
            subprocess.run([compiler, '-parse-as-library', str(p/'main.swift'), '-o', str(p/'fixture')], check=True)
            subprocess.run([str(p/'fixture')], check=True, timeout=45)

if __name__ == '__main__': unittest.main(verbosity=2)
