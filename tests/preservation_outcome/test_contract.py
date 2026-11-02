"""Post-dispatch preservation outcome contract; native lane requires swiftc."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
def read(path):
    return (ROOT / path).read_text()
def declaration(source, marker):
    start = source.index(marker)
    pos = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}')
        pos += 1
    return source[start:pos]

class Contract(unittest.TestCase):
    def test_failure_after_evidence_and_no_expiry_advance(self):
        src = read('SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift')
        record = src.index('self.context.recordRefreshVerification?(verification)')
        update = src.index('try self.updateInstalledApp(profiles: profiles', record)
        fail = src.index('V3PreservationPostDispatchFailure.outcome(for: verification)', update)
        finish = src.index('return installedApp', fail)
        self.assertLess(record, update)
        self.assertLess(update, fail)
        self.assertLess(fail, finish)
        updater = declaration(src, 'private func updateInstalledApp(')
        self.assertLess(updater.index('observed.profileStore == .matched'), updater.index('installedApp.update(provisioningProfile: mainProfile)'))
        self.assertIn('else { return installedApp }', updater)
        self.assertIn('if context.isPreservationRefresh { return installedApp }', updater)

    def test_real_install_once_and_failure_manifest(self):
        refresh = read('SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift')
        wrapper = read('SideStore/Core/DeviceApi/MinimuxerWrapper.swift')
        install = declaration(wrapper, 'func installPreservationProvisioningProfile(')
        self.assertIn('minimuxer.core.installProvisioningProfile(profile: profileData)', install)
        self.assertNotIn('withRemotePairingRetry', install)
        self.assertEqual(refresh.count('try await installPreservationProvisioningProfile(p.value.data)'), 1)
        caught = refresh[refresh.index('} catch let selection as V3RefreshSelectionFailure'):refresh.index('self.setProgress(80)')]
        self.assertNotIn('readProfilesWithoutMutation()', caught)
        self.assertNotIn('installPreservationProvisioningProfile(', caught)
        runner = read('SideStore/Core/Operations/PipelineRunner.swift')
        self.assertIn('group.set(.failure(mappedError), forAppWithBundleIdentifier: operation.bundleIdentifier)', runner)
        bg = read('SideStore/Core/Operations/StandaloneOperations/BackgroundRefreshAppsOperation.swift')
        branch = bg[bg.index('private func persistAutomaticRefreshVerification('):bg.index('private func startListeningForRunningApps()', bg.index('private func persistAutomaticRefreshVerification('))]
        self.assertIn('case .failure(let error):', branch)
        self.assertIn('"success": false', branch)
        self.assertIn('row["verification"] = verification.wire', branch)
        self.assertLess(branch.index('case .success(let app):'), branch.index('REFRESH_VERIFIED'))
        self.assertLess(branch.index('REFRESH_VERIFIED'), branch.index('case .failure(let error):'))

    def test_swift_outcome_runtime(self):
        swift = shutil.which('swiftc')
        if not swift:
            if os.environ.get('V3_REQUIRE_SWIFT') == '1': self.fail('swiftc required')
            self.skipTest('swiftc unavailable; native outcome behavior not executed')
        src = read('SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift')
        outcome = declaration(src, 'enum V3PreservationPostDispatchFailure:')
        # Extract the actual SS wire producer and LC wire parser, not a model
        # duplicate. The remaining driver invokes the pure decision helper; it
        # is not an end-to-end device, pipeline or manifest execution test.
        verification = src[src.index('struct V3RefreshVerification:'):src.index('    static func readProfiles(', src.index('struct V3RefreshVerification:'))] + "}\n"
        host = Path(os.environ.get('V3_HOST_SOURCE_ROOT', str(ROOT.parent / 'LC')))
        host_src = (host / 'SideStoreSupport/SideStore.swift').read_text()
        parser = declaration(host_src, 'public struct V3RefreshProfileEvidence {')
        fixture = 'import Foundation\nimport CoreFoundation\n' + verification + outcome + '\n' + parser + '''
@main struct Main {
    static func main() {
        var verified = V3RefreshVerification()
        verified.profileStore = .matched; verified.renewal = .extended
        verified.certificate = "valid"; verified.preservation = "authorizationPreserved"
        precondition(V3PreservationPostDispatchFailure.outcome(for: verified) == nil)
        let parsed = V3RefreshProfileEvidence(verified.wire)!
        precondition(parsed.isRenewed && parsed.preservation == "authorizationPreserved")
        var v = verified; v.profileStore = .unavailable; v.renewal = .unknown
        v.certificate = "unknown"; v.preservation = nil
        precondition(V3PreservationPostDispatchFailure.outcome(for: v) == .verificationUnavailable)
        let unavailable = V3RefreshProfileEvidence(v.wire)!
        precondition(unavailable.installAcknowledged && unavailable.profileStore == "unavailable" && !unavailable.isRenewed)
        v.profileStore = .mismatch
        precondition(V3PreservationPostDispatchFailure.outcome(for: v) == .verificationMismatch)
        let mismatch = V3RefreshProfileEvidence(v.wire)!
        precondition(mismatch.installAcknowledged && mismatch.profileStore == "mismatch" && !mismatch.isRenewed)
        v = verified; v.preservation = nil
        precondition(V3PreservationPostDispatchFailure.outcome(for: v) == .verificationMismatch)
        v = verified; v.installAcknowledged = false
        precondition(V3PreservationPostDispatchFailure.outcome(for: v) == .verificationMismatch)
        v = verified; v.renewal = .unchanged
        precondition(V3PreservationPostDispatchFailure.outcome(for: v) == .verificationMismatch)
        v = verified; v.certificate = "invalid"
        precondition(V3PreservationPostDispatchFailure.outcome(for: v) == .verificationMismatch)
        print("PASS 7 actual outcome cases and SS-to-LC wire")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='preservation-outcome-') as tmp:
            source = Path(tmp) / 'fixture.swift'; exe = Path(tmp) / 'fixture'
            source.write_text(fixture)
            result = subprocess.run([swift, '-parse-as-library', str(source), '-o', str(exe)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            marker = 'PASS 7 actual outcome cases and SS-to-LC wire'
            self.assertEqual(result.stdout.strip(), marker)
            print(marker)

if __name__ == '__main__': unittest.main()
