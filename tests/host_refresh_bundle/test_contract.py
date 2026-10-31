"""Source-owned guard/integration assertions. No native, network or device work."""
from pathlib import Path
import argparse
import json


def owned_pipeline_lifetime(runner: str) -> bool:
    """Actual operation scope, not an unrelated defer elsewhere in the file."""
    try:
        start = runner.index('    private func performPipeline(')
        body_start = runner.index('{', start)
        end, depth = body_start + 1, 1
        while depth:
            depth += (runner[end] == '{') - (runner[end] == '}')
            end += 1
        body = runner[body_start:end]
        cleanup = body.index('defer { preparedHostRefreshBundle?.removeOwnedCopy() }')
        awaited = body.index('let completedApp = try await PipelineExecutor.shared.executePipeline(')
        evidence = body.index('group.setVerification(verification, for: completedApp.bundleIdentifier)')
        returned = body.index('return completedApp')
        return cleanup < awaited < evidence < returned
    except (ValueError, IndexError):
        return False


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
    check(owned_pipeline_lifetime(runner), 'Cleanup surrounds awaited pipeline and evidence-preserving return')
    cleanup = 'defer { preparedHostRefreshBundle?.removeOwnedCopy() }'
    check(not owned_pipeline_lifetime(runner.replace(cleanup, '', 1)), 'Negative missing owned cleanup rejected')
    moved = runner.replace(cleanup, '', 1).replace('return completedApp', cleanup + '\n        return completedApp', 1)
    check(not owned_pipeline_lifetime(moved), 'Negative late cleanup registration rejected')
    early = runner.replace('let completedApp = try await PipelineExecutor.shared.executePipeline(', 'return completedApp\n        let completedApp = try await PipelineExecutor.shared.executePipeline(', 1)
    check(not owned_pipeline_lifetime(early), 'Negative return before pipeline rejected')
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
    check('context.acknowledgedReuseMainIdentity = V3ValidatedReuseMainRegistry.acknowledgedIdentity(' in integration, 'Separate acknowledged history consumer')
    check('sourceDigest: AppBundleFingerprint.compute(for: source.fileURL)' in integration, 'Original source digest bound to history')
    check('V3ValidatedReuseMainRegistry.contains(' not in integration, 'Original payload nonce is not signed installation evidence')
    check('context.validatedReuseMain = false' in integration, 'Historical evidence does not authorize live refresh')
    return checks


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate-root', '--repo', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    print(json.dumps({'schema': 'v3-host-refresh-bundle-source-v1', 'pass': True,
                      'assertion_count': validate(args.candidate_root), 'swift_executed': False,
                      'network_executed': False, 'provider_executed': False, 'device_executed': False}, sort_keys=True))
