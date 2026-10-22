#!/usr/bin/env python3
"""Project actual deferred setup methods with inert Apple/device/storage boundaries."""
import argparse, hashlib, json
from pathlib import Path

CASE_NAMES = [
    'configured_success_registers_and_completes',
    'missing_pairing_defers_after_certificate_and_checked_activation',
    'reset_pairing_defers_without_adopting_stale_record',
    'present_invalid_empty_and_unreadable_never_defer',
    'network_udid_portal_and_certificate_failures_never_defer',
    'background_retry_reauth_and_skip_modes_never_defer',
    'failed_activation_never_publishes_deferred_success',
    'stale_identity_wrong_team_or_key_never_activates',
    'cancellation_before_or_during_activation_never_succeeds',
    'deferred_completion_skips_resign_and_postauth',
    'wire_outcome_allowlist_preserves_incomplete_journal',
]

def block(source, anchor):
    assert source.count(anchor)==1, (anchor, source.count(anchor))
    start=source.index(anchor); end=source.index('{',start)+1; depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}'); end+=1
    return source[start:end]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args(); root=args.sources; out=args.output_dir; out.mkdir(parents=True,exist_ok=True)
    owners={
      'operation': 'SideStore/SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift',
      'pairing': 'SideStore/SideStore/Core/Pairing/PairingFileManager.swift',
      'service': 'SideStore/AltStore/AppDelegate.swift',
      'host': 'LiveContainer/SideStoreSupport/SideStore.swift',
      'ui': 'LiveContainer/LiveContainerSwiftUI/Views/V3UnifiedShell.swift',
    }
    sources={k:(root/p).read_text() for k,p in owners.items()}
    policy=block(sources['service'],'enum V3DeviceSetupDeferralPolicy {')
    assert policy==block(sources['host'],'enum V3DeviceSetupDeferralPolicy {')
    assert policy==block(sources['ui'],'enum V3DeviceSetupDeferralPolicy {')
    methods=['private func performProvisioningLoop(', 'private func performFinalizeAuthentication(', 'private func v3ValidateDeferredIdentity(']
    code='import Foundation\n'+policy+'\n'+block(sources['operation'],'struct SignInResult {')+'\n'
    code+='final class DeferredFixtureOperation: DeferredOperationBoundary {\n'
    code+='\n'.join(block(sources['operation'],a) for a in methods)
    code+='''
    func run() async throws -> SignInResult {
        let result = try await performProvisioningLoop(account: Boundary.account, session: Boundary.session, reportProgress: { _ in })
        try await performFinalizeAuthentication(result: .success(result))
        Boundary.events.append("returned")
        return result
    }
}
'''
    code+='final class PairingFileManager: PairingBoundary {\nstatic let shared = PairingFileManager()\n'+block(sources['pairing'],'nonisolated var v3DeviceSetupIsUnconfigured: Bool {')+'\n}\n'
    (out/'CandidateDeferredSetup.swift').write_text(code)
    here=Path(__file__).resolve().parent
    for name in ['BoundaryDoubles.swift','RuntimeTests.swift']:
        (out/name).write_bytes((here/name).read_bytes())
    closure=['CandidateDeferredSetup.swift','BoundaryDoubles.swift','RuntimeTests.swift']
    fixture_inputs={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in here.iterdir() if p.is_file() and p.suffix in ['.py','.swift','.md']}
    evidence={'schema':'deferred-device-setup-source-evidence-v1','inputs':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in owners.values()},
      'fixture_inputs':fixture_inputs,'extracted_anchors':methods+['enum V3DeviceSetupDeferralPolicy {','nonisolated var v3DeviceSetupIsUnconfigured: Bool {'],
      'output_closure':closure,'outputs':{p:hashlib.sha256((out/p).read_bytes()).hexdigest() for p in closure},
      'boundary_replacements':['Apple portal and team/certificate acquisition are inert doubles','Core Data checked save is an in-memory success/failure boundary','Keychain identity and cryptographic key proof use synthetic facts only','Pairing file and bundle reads use in-memory metadata only','Sign-in UI, resign and post-auth record calls only'],
      'case_names':CASE_NAMES,'network':False,'native_provider':False,'swift_executed':False}
    evidence['inputs'].update(fixture_inputs)
    (out/'source-evidence.json').write_text(json.dumps(evidence,indent=2,sort_keys=True)+'\n')

if __name__=='__main__': main()
