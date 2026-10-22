#!/usr/bin/env python3
"""Static integration/negative controls for the actual placement source; no native execution."""
import argparse,importlib.util,json,tempfile,subprocess,sys
from pathlib import Path

def main():
 p=argparse.ArgumentParser();p.add_argument('--sources',type=Path,required=True);a=p.parse_args();r=a.sources
 here=Path(__file__).resolve().parent
 spec=importlib.util.spec_from_file_location('placed_generator',here/'generate_fixture.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 manager=(r/'SideStore/SideStore/Core/Pairing/PairingFileManager.swift').read_text()
 boot=(r/'SideStore/SideStore/AppBootManager.swift').read_text()
 service=(r/'SideStore/AltStore/AppDelegate.swift').read_text()
 host=(r/'LiveContainer/SideStoreSupport/SideStore.swift').read_text()
 ui=(r/'LiveContainer/LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
 defaults=(r/'SideStore/AltStore/Core/Extensions/UserDefaults+AltStore.swift').read_text();assert 'isPairingReset' in defaults
 fetch=m.block(manager,'nonisolated func fetchPairingFile(preferred:')
 assert 'guard !UserDefaults.standard.isPairingReset else { return nil }' in fetch
 prepare=m.block(manager,'func preparePlacedImport()')
 assert prepare.index('parse(content: content, preferred: selected)')<prepare.index('return PlacedImport(')
 assert 'destination?.data == source.data' in prepare
 commit=m.block(manager,'func commitPlacedImport(')
 assert commit.index('Task.checkCancellation()')<commit.index('validatePlacedImport(plan)')<commit.index('directory.publish')<commit.index('isPairingReset = false')
 assert '.resolvingSymlinksInPath()' in manager and 'openat(descriptor' in manager and 'O_NOFOLLOW' in manager
 assert 'maximumBytes + 1 - data.count' in manager and 'fstatat(descriptor, name, &pathInfo, AT_SYMLINK_NOFOLLOW)' in manager
 publish=m.block(manager,'func publish(')
 assert 'linkat(descriptor, staging, descriptor, name, 0)' in publish and 'stored.inode == staged.inode' in publish
 assert 'current.st_ino' in publish and 'unlinkat(descriptor, name, 0)' in publish
 life=m.block(boot,'enum V3PlacedPairingLifecycle {')
 ordered=['try validate()', 'try commit()', 'try Task.checkCancellation()', 'try validateCommitted()', 'try await start()', 'try Task.checkCancellation()', 'try validateCommitted()', 'try await verify()', 'try Task.checkCancellation()', 'try validateCommitted()']
 cursor=life.index('try validate()')
 for item in ordered: cursor=life.index(item,cursor)+len(item)
 assert 'await Task { @MainActor in await rollback() }.value' in life
 action=m.block(boot,'func usePlacedPairingFile() async throws')
 assert 'V3PairingActivationGate.withExclusiveAccess' in action
 assert action.index('try await minimuxerStop()')<action.index('startMinimuxerUnlocked')
 assert 'verifyLiveIdentity: false' in action and 'V3PlacedPairingReadiness.verify(expectedUDID: plan.expectedUDID)' in action
 readiness=m.block(boot,'enum V3PlacedPairingReadiness {')
 assert 'expectedUDID == nil || expectedUDID == live' in readiness
 assert 'minimuxer.gateway.getLockdownValue(key: "UniqueDeviceID")' in readiness
 assert 'core.fetchUDID()' not in readiness
 assert 'beginTransportBatch()' in readiness and readiness.count('endTransportBatch()')==2
 boot_sequence=m.block(boot,'public nonisolated func performBootSequence() async')
 assert boot_sequence.index('V3PairingActivationGate.runBootIfNeeded')<boot_sequence.index('fetchPairingFile()')
 assert 'placementOwnsStartup = true' in action
 gate=m.block(boot,'enum V3PairingActivationGate {')
 assert 'guard !placementOwnsStartup else { return }' in gate
 assert 'preparePlacedImport' not in boot_sequence and 'isPairingReset = false' not in boot_sequence
 for text in [service,host]:
  wire=m.block(text,'enum V3WireContract {')
  assert '"signOut", "pairingUsePlaced"' in wire
  for anchor in ['enum V3HostDirectRecoveryRecord', 'struct V3HostDirectRecoveryRecord']:
   if anchor in text:assert '"pairingUsePlaced"' in m.block(text,anchor)
  assert '"pairingUsePlaced"' in m.block(text,'enum V3StatusAuthorityOperationPolicy {')
 assert '"pairingUsePlaced"' in m.block(service,'struct V3DirectMutationRecoveryRecord {')
 view=m.block(ui,'struct V3PairingView: View {')
 assert 'Use Placed Pairing File' in view and '.onDisappear { placementTask?.cancel() }' in view
 assert 'guard !working else { return }' in m.block(view,'private func usePlacedPairing()')
 for forbidden in ['print(plan.content)', 'debugLog(plan.content)', 'print(live)', 'debugLog(live)']:
  assert forbidden not in action
 with tempfile.TemporaryDirectory() as tmp:
  subprocess.run([sys.executable,str(here/'generate_fixture.py'),'--sources',str(r.resolve()),'--output',tmp],check=True)
  manifest=json.loads((Path(tmp)/'source-evidence.json').read_text())
  assert len(manifest['case_names'])==27 and len(set(manifest['case_names']))==27
 print('PLACED_PAIRING_STATIC_PASS')
if __name__=='__main__':main()
