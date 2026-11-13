from pathlib import Path
import unittest
import shutil
import subprocess
import tempfile
import os

ROOT = Path(__file__).resolve().parents[2]

class Contract(unittest.TestCase):
    def test_preflight_before_extension_registration(self):
        s = (ROOT / 'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift').read_text()
        check = s.index('let reasons = try await reuseMainRejectionReasons(app: targetAppBundle, profile: profile)')
        register = s.index('try await withThrowingTaskGroup')
        self.assertLess(check, register)
        self.assertIn('confirmSeparateExtensionProvisioning(', s[check:register])
        self.assertIn('self.context.useMainProfile = false', s[check:register])
        self.assertIn('customEntitlementOverridesRequireSeparateProfiles', s)
        self.assertIn('throw OperationError.cancelled', s[check:register])

    def test_explicit_signer_mode(self):
        s = (ROOT / 'SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift').read_text()
        self.assertIn('if context.useMainProfile && context.validatedReuseMain {', s)
        self.assertIn('extensionStrategy: .reuseMainWhenCompatible', s)

    def test_headless_fails_closed(self):
        s = (ROOT / 'SideStore/Core/Operations/PipelineExecutionHandler.swift').read_text()
        self.assertIn('extensionCount: Int) async throws -> Bool { false }', s)

    def test_fallback_explanation_and_no_silent_stripping(self):
        s = (ROOT / 'AltStore/AppDelegate.swift').read_text()
        self.assertIn('extensionSigningFallback', s)
        self.assertIn('Keep All With Separate Profiles', s)
        self.assertIn('V3ReuseMainExplanation.fallback(', s)
        self.assertIn('V3ReuseMainExplanation.offer(extensionCount: sorted.count)', s)
        fetch = (ROOT / 'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift').read_text()
        self.assertIn('extensionReasonCodes: reuseMainRejectionDetails', fetch)
        self.assertIn('reuseMainRejectionDetails[ext.bundleIdentifier] = decision.reasons', fetch)
        self.assertIn('Experimental ReuseMain', s)

    def test_legacy_is_not_enrolled(self):
        runner = (ROOT / 'SideStore/Core/Operations/PipelineRunner.swift').read_text()
        self.assertIn('V3ValidatedReuseMainRegistry.acknowledgedIdentity(', runner)
        self.assertNotIn('V3ValidatedReuseMainRegistry.contains(', runner)
        self.assertIn('sourceDigest: AppBundleFingerprint.compute(for: source.fileURL)', runner)
        self.assertIn('context.validatedReuseMain = false', runner)
        install = (ROOT / 'SideStore/Core/Operations/PipelineOperations/InstallAppOperation.swift').read_text()
        self.assertLess(install.index('try await installAppBundle('), install.index('V3ValidatedReuseMainRegistry.didAcknowledgeInstall('))
        self.assertNotIn('V3ValidatedReuseMainRegistry.stage(', install)
        self.assertIn('!isSelfReinstall', install)
        resign = (ROOT / 'SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift').read_text()
        self.assertIn('UUID().uuidString', resign)
        self.assertIn('infoDictionary.removeValue(forKey: V3ValidatedReuseMainRegistry.generationKey)', resign)
        self.assertNotIn('profileUUID: context.targetAppBundle?.provisioningProfile?.uuid', runner)
        self.assertIn('certificateDER: certificateDER', install)
        fetch = (ROOT / 'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift').read_text()
        self.assertIn('Experimental ReuseMain is not available for host self-install', fetch)
        self.assertIn('if self.context.validatedReuseMain, !appExtensions.isEmpty', fetch)
        self.assertIn('validateExtensionSigningCapabilities = self.context.validatedReuseMain', fetch)
        handler = (ROOT / 'SideStore/Core/Operations/PipelineOperations/RemoveAppExtensionsOperation.swift').read_text()
        self.assertIn('case .keepAllValidatedReuseMain:', handler)
        self.assertIn('self.context.validatedReuseMain = false', handler)

    def test_trusted_refresh_association(self):
        s = (ROOT / 'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift').read_text()
        for marker in ['installed.useMainProfile', 'installed.resignedBundleIdentifier == app.bundleIdentifier',
                       'ext.provisioningProfile?.data == app.provisioningProfile?.data',
                       'originalExtensionBundleIdentifier: ext.bundleIdentifier']:
            self.assertIn(marker, s)

    def test_group_mapping_is_provisioning_bound_and_fallback_only(self):
        s = (ROOT / 'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift').read_text()
        self.assertIn('private actor GroupAssignments', s)
        self.assertLess(s.index('context.provisionedAppGroupMappings = [:]'), s.index('if context.isPreservationRefresh'))
        self.assertLess(s.index('try await DeveloperPortalProxy.shared.assignAppID(appID, to: Array(groups), team: team)'),
                        s.index('await groupAssignments.record(bundleID: appID.bundleIdentifier, mapping: assignedMapping)'))
        self.assertIn('assignedMapping[groupIdentifier] = adjustedGroupIdentifier', s)
        self.assertIn('guard group.groupIdentifier == adjustedGroupIdentifier else', s)
        self.assertIn('if context.validatedReuseMain && !context.useMainProfile && context.legacyReplacementBinding == nil', s)
        self.assertLess(s.index('try await withThrowingTaskGroup'), s.index('context.provisionedAppGroupMappings = await groupAssignments.snapshot()'))
        signer = (ROOT / 'SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift').read_text()
        self.assertIn('provisionedAppGroupMappings: context.provisionedAppGroupMappings', signer)
        self.assertIn('extensionStrategy: .perExtensionPreservingCapabilities', signer)

    def test_group_mapping_actor_native_run_isolation(self):
        compiler = shutil.which('swiftc')
        if not compiler:
            if os.environ.get('V3_REQUIRE_SWIFT') == '1': self.fail('swiftc required')
            self.skipTest('native Swift qualification required')
        source = (ROOT / 'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift').read_text()
        start = source.index('private actor GroupAssignments')
        end = source.index('    private let groupAssignments', start)
        actor = source[start:end].replace('private actor', 'actor', 1)
        fixture = actor + r'''
@main struct Cases {
    static func main() async {
        let records = GroupAssignments()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { await records.record(bundleID: "bundle.\(i)", mapping: ["group.source": "group.assigned.\(i)"]) }
            }
        }
        let first = await records.snapshot()
        precondition(first.count == 20)
        await records.reset()
        let empty = await records.snapshot()
        precondition(empty.isEmpty)
        await records.record(bundleID: "new.run", mapping: ["source": "assigned"])
        let next = await records.snapshot()
        precondition(next.count == 1 && next["new.run"] != nil)
        precondition(first.count == 20)
    }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'Actor.swift').write_text(fixture)
            result = subprocess.run([compiler, '-parse-as-library', '-swift-version', '6', str(path / 'Actor.swift'), '-o', str(path / 'actor')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run([str(path / 'actor')], check=True)

    def test_custom_bundle_id_lookup(self):
        s = (ROOT / 'SideStore/Core/Operations/PipelineOperations/PrepareAppExtensionBundleIDsOperation.swift').read_text()
        self.assertIn('provisioningProfiles?[self.context.targetBundleIdentifier]', s)
        self.assertIn('appexBundleIds[effectiveExtensionID]', s)
        self.assertNotIn('.replacingOccurrences(', s)

if __name__ == '__main__': unittest.main()
