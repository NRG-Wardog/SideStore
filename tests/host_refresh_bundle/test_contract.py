"""Source-owned guard/integration assertions. No native, network or device work."""
from pathlib import Path
import argparse
import json


def validate(repo: Path) -> int:
    runner = (repo / 'SideStore/Core/Operations/PipelineRunner.swift').read_text()
    helper = runner.split('// V3_HOST_REFRESH_BUNDLE_PREPARATION_BEGIN\n', 1)[1].split('// V3_HOST_REFRESH_BUNDLE_PREPARATION_END', 1)[0]
    integration = runner.split('        var preparedHostRefreshBundle:', 1)[1].split('        context.beginInstallationHandler', 1)[0]
    checks = 0
    def check(value, message):
        nonlocal checks
        if not value:
            raise AssertionError(message)
        checks += 1
    check('if case .refresh = operation, context.targetAppBundle == nil,' in integration, 'Refresh-only nil-cache selector')
    check('app.bundleIdentifier == StoreApp.altstoreAppID' in integration, 'Exact original self selector')
    check('context.targetAppBundle = ALTApplication(fileURL: app.fileURL)' in integration, 'Existing cache load retained')
    check(integration.index('context.targetAppBundle = ALTApplication(fileURL: app.fileURL)') < integration.index('V3HostRefreshBundlePreparation.prepare('), 'Cache wins before recovery')
    for field in ['installedApp = app', 'appBundleFingerprint = app.appBundleFingerprint', 'useMainProfile = app.useMainProfile', 'customBundleIdentifier = app.customBundleIdentifier']:
        check('context.' + field in integration, 'Preserved context field ' + field)
    check('defer { preparedHostRefreshBundle?.removeOwnedCopy() }' in runner, 'Operation scope cleanup')
    check(runner.index('defer { preparedHostRefreshBundle?.removeOwnedCopy() }') < runner.index('return try await PipelineExecutor.shared.executePipeline('), 'Cleanup surrounds awaited pipeline')
    check('try Task.checkCancellation()\n                            try V3RemoteRequestLeases.admitted?.check()' in integration, 'Cancellation plus current admission retained')
    check('if error is CancellationError { throw error }' in integration, 'Cancellation not remapped')
    check('stage: "command", sourceStep: nil' in integration, 'Preparation failures use neutral stage, not profile fetch or selected IPA')
    for identity in ['originalBundleID == expectedOriginalBundleID', 'resignedBundleID == activeBundleID', 'source.bundleIdentifier == resignedBundleID', 'source.provisioningProfile != nil']:
        check(identity in helper, 'Required host identity check ' + identity)
    check('Set(sourceExtensionIDs) == Set(originalByResigned.keys)' in helper, 'Exact extension set')
    check('originalIDs.insert(identity.original).inserted' in helper and 'originalByResigned[identity.resigned] == nil' in helper, 'Unique original/resigned extension map')
    check('identity.original.dropFirst(originalBundleID.count) == identity.resigned.dropFirst(resignedBundleID.count)' in helper, 'Extension suffix preserved')
    check('AppBundleFingerprint.compute(for: copyURL) == sourceFingerprint' in helper, 'Exact copy fingerprint')
    check(helper.count('AppBundleFingerprint.compute(for: activeBundleURL)') == 3, 'Source before/after copy and canonicalization verification')
    check(helper.count('try checkAdmission()') == 5, 'Five preparation cancellation/admission boundaries')
    check('UUID().uuidString' in helper and 'withIntermediateDirectories: false' in helper, 'Unique operation-owned staging')
    check('defer { if !published { try? FileManager.default.removeItem(at: owner) } }' in helper, 'Failed partial copy cleanup')
    check('try copy.updateInfoPlist' in helper and 'try appExtension.updateInfoPlist' in helper, 'Only scratch metadata normalized')
    for forbidden in ['cachePayload(', 'targetSigningCertificate', 'appendTeamID =', 'appBundleFingerprint =', 'source.updateInfoPlist', 'removeItem(at: activeBundleURL)', 'URLSession', 'DeveloperPortalProxy']:
        check(forbidden not in helper, 'No broadened mutation: ' + forbidden)
    check('context.validatedReuseMain = app.useMainProfile && V3ValidatedReuseMainRegistry.contains(' in integration, 'Explicit opt-in and persisted payload association required')
    check('profileUUID: context.targetAppBundle?.provisioningProfile?.uuid' in integration, 'Profile UUID bound to cached payload')
    check('generation: context.targetAppBundle?.infoPlist[V3ValidatedReuseMainRegistry.generationKey]' in integration, 'Signed generation bound to cached payload')
    check('if app.useMainProfile && !context.validatedReuseMain &&' in integration and 'V3ValidatedReuseMainRegistry.hasAssociation(' in integration and 'throw OperationError.invalidParameters(' in integration, 'Known validated association cannot silently downgrade')
    return checks


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate-root', '--repo', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    print(json.dumps({'schema': 'v3-host-refresh-bundle-source-v1', 'pass': True,
                      'assertion_count': validate(args.candidate_root), 'swift_executed': False,
                      'network_executed': False, 'provider_executed': False, 'device_executed': False}, sort_keys=True))
