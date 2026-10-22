#!/usr/bin/env python3
"""Extract production placement transaction and lifecycle. Fake boundary only; never devices/network."""
import argparse,hashlib,json
from pathlib import Path
CASE_NAMES = [
 'fresh-place-explicit-adoption', 'boot-and-status-preserve-reset', 'invalid-placement-no-mutation',
 'reset-with-no-file-preserved', 'changed-placement-after-commit-stops-transport', 'changed-preference-after-commit-not-overwritten',
 'failed-startup-retains-adopted-file', 'cancelled-startup-retains-adopted-file', 'failed-live-identity-retains-adopted-file',
 'cleanup-uncertainty-retains-file-and-hold', 'conflicting-destination-preserved', 'symlink-placement-rejected',
 'symlink-directory-rejected', 'oversized-file-rejected', 'directory-replacement-rejected',
 'stale-before-commit-no-adoption', 'verified-existing-copy-adopted', 'commit-cancellation-preserves-reset',
 'activation-gate-serializes', 'diagnostics-do-not-contain-pairing-data', 'cached-device-id-is-not-live-proof',
 'different-live-device-not-ready', 'actual-live-query-ready', 'failed-publication-cleanup-quarantines-leftover',
 'changed-state-after-live-query-not-ready', 'queued-boot-does-not-retry-not-ready', 'queued-boot-does-not-override-cleanup-uncertain',
 'saved-selection-restores-from-safe-file', 'selected-file-missing', 'reset-leftover-not-selected', 'changed-source-not-selected', 'changed-preference-not-selected', 'malformed-selected-file-no-green', 'unsafe-selected-file-no-green', 'source-removed-saved-selection-retained', 'repeated-identical-selection-no-restart', 'repeated-unready-selection-retries-without-commit', 'repeated-unready-selection-retains-file', 'reset-during-probe-no-ready', 'changed-source-during-probe-no-ready', 'changed-destination-during-probe-no-ready', 'owner-change-during-probe-no-ready', 'cancelled-probe-no-restart', 'view-reentry-file-only-status', 'unknown-selection-never-green', 'missing-receipt-restarts-without-recommit', 'changed-receipt-during-probe-no-ready', 'transport-receipt-binds-input-and-protocol', 'stale-start-cannot-revive-receipt']

def block(source, anchor):
 assert source.count(anchor)==1, anchor
 start=source.index(anchor); i=source.index('{', start)+1; depth=1
 while depth: depth+=(source[i]=='{')-(source[i]=='}'); i+=1
 return source[start:i]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--sources',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 paths=['SideStore/SideStore/Core/Pairing/PairingFileManager.swift','SideStore/SideStore/AppBootManager.swift','SideStore/AltStore/AppDelegate.swift','LiveContainer/SideStoreSupport/SideStore.swift','LiveContainer/LiveContainerSwiftUI/Views/V3UnifiedShell.swift','SideStore/SideStore/Core/DeviceApi/MinimuxerWrapper.swift']
 texts=[(a.sources/x).read_text() for x in paths]
 manager=block(texts[0],'final class PairingFileManager: NSObject {')
 manager=manager.replace(block(manager,'    static var supportedContentTypes: [UTType] {'),'')
 source='import Foundation\nimport Darwin\nimport CryptoKit\n'+block(texts[0],'public struct PairingFileMetadata: Sendable {')+'\n'+block(texts[0],'enum V3PairingSelectionState: String {')+'\n'+manager+'\n'
 for anchor in ['enum V3PlacedPairingError: Error, Equatable {','final class V3PlacedPairingDirectory {']:source+=block(texts[0],anchor)+'\n'
 source+=block(texts[1],'enum V3PlacedPairingOutcome: String {')+'\n'
 source+=block(texts[4],'enum V3PairingSelectionPresentation {')+'\n'
 source+=block(texts[5],'final class V3PairingTransportReceipt: @unchecked Sendable {')+'\n'
 for anchor in ['enum V3PairingActivationGate {','enum V3PlacedPairingReadiness {','enum V3PlacedPairingLifecycle {']:source+='@MainActor\n'+block(texts[1],anchor)+'\n'
 # Verify the actual service -> host -> view connects the tested lifecycle.
 assert 'V3PlacedPairingLifecycle.run(' in block(texts[1],'func usePlacedPairingFile(')
 assert 'manager.commitPlacedImport(plan)' in texts[1]
 for text in texts[2:5]:
  assert '"pairingImportData", "pairingUsePlaced", "settingsSet"' in text
  assert 'case "pairingUsePlaced": return "placed pairing activation"' in text
 assert 'case "pairingUsePlaced":\n            let outcome = try await V3BackendCommands.pairingUsePlaced(id: id)' in texts[2]
 assert 'AppBootManager.shared.usePlacedPairingFile(validateOperation:' in texts[2]
 view=block(texts[4],'struct V3PairingView: View {')
 assert 'request(operation: "pairingUsePlaced")' in view and '.onDisappear { placementTask?.cancel() }' in view
 assert 'Use Placed Pairing File' in view and 'status.reload()' not in block(view,'private func usePlacedPairing()')
 for text in texts[2:4]:
  wire=block(text,'enum V3WireContract {')
  assert '"signOut", "pairingUsePlaced"' in wire
  reads=wire[wire.index('static let readOperations:'):wire.index('static func decodeRequest')]
  assert 'pairingUsePlaced' not in reads
 # Privacy: the new transaction logs no data, and the public failure is finite.
 tx=texts[0][texts[0].index('    struct PlacedImport {'):]
 assert 'debugLog' not in tx[:tx.index('    func deletePairingFile')]
 assert 'error.localizedDescription' not in block(texts[2],'static func pairingUsePlaced(id: String)')
 a.output.mkdir(parents=True,exist_ok=True)
 (a.output/'Production.swift').write_text(source)
 here=Path(__file__).resolve().parent
 for name in ['Doubles.swift','RuntimeTests.swift']:(a.output/name).write_bytes((here/name).read_bytes())
 closure=['Production.swift','Doubles.swift','RuntimeTests.swift']
 manifest={'schema':'placed-pairing-source-evidence-v1','inputs':{**{x:sha(a.sources/x) for x in paths}, 'SideStore/AltStore/Core/Extensions/UserDefaults+AltStore.swift':sha(a.sources/'SideStore/AltStore/Core/Extensions/UserDefaults+AltStore.swift'), **{str(Path('SideStore/.ci/placed-pairing')/x):sha(here/x) for x in ['generate_fixture.py','test_source.py','Doubles.swift','RuntimeTests.swift']}},'output_closure':closure,'outputs':{x:sha(a.output/x) for x in closure},'boundary_replacements':['UniformTypeIdentifiers UI-only property omitted','synthetic parser and pairing protocols','in-memory preference store','temporary sandbox Documents path','fake startup/cleanup closures', 'live gateway API double (production readiness method extracted)', 'unlinkat failure injection for owned destination cleanup'],'network':False,'native_provider':False,'swift_executed':False,'case_names':CASE_NAMES}
 (a.output/'source-evidence.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print('PLACED_PAIRING_SOURCE_PASS')
if __name__=='__main__':main()
