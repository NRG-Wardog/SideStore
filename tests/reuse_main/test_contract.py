from pathlib import Path
import unittest

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
        self.assertIn('reasonCodes.sorted()', s)
        self.assertIn('Experimental ReuseMain', s)

    def test_legacy_is_not_enrolled(self):
        runner = (ROOT / 'SideStore/Core/Operations/PipelineRunner.swift').read_text()
        self.assertIn('V3ValidatedReuseMainRegistry.contains(', runner)
        self.assertIn('generation: context.targetAppBundle?.infoPlist', runner)
        install = (ROOT / 'SideStore/Core/Operations/PipelineOperations/InstallAppOperation.swift').read_text()
        self.assertLess(install.index('try await installAppBundle('), install.index('V3ValidatedReuseMainRegistry.didInstall('))
        self.assertNotIn('V3ValidatedReuseMainRegistry.stage(', install)
        self.assertIn('!isSelfReinstall', install)
        resign = (ROOT / 'SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift').read_text()
        self.assertIn('UUID().uuidString', resign)
        self.assertIn('infoDictionary.removeValue(forKey: V3ValidatedReuseMainRegistry.generationKey)', resign)
        self.assertIn('profileUUID: context.targetAppBundle?.provisioningProfile?.uuid', runner)
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

    def test_custom_bundle_id_lookup(self):
        s = (ROOT / 'SideStore/Core/Operations/PipelineOperations/PrepareAppExtensionBundleIDsOperation.swift').read_text()
        self.assertIn('provisioningProfiles?[self.context.targetBundleIdentifier]', s)
        self.assertIn('appexBundleIds[effectiveExtensionID]', s)
        self.assertNotIn('.replacingOccurrences(', s)

if __name__ == '__main__': unittest.main()
