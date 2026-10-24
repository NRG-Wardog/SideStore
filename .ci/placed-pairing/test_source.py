#!/usr/bin/env python3
"""Static integration/negative controls for the actual placement source; no native execution."""
import argparse,importlib.util,json,tempfile,subprocess,sys,re
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
 action=m.block(boot,'func usePlacedPairingFile(')
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
 assert 'alreadySelected: plan.isCurrentSelection' in action
 assert 'mayReuseTransport: transportTicket != nil' in action
 assert 'minimuxerPairingProtocol() == plan.mode' in action
 assert 'V3PairingTransportReceipt.shared.ticket(contents: plan.content, mode: plan.mode) == transportTicket' in action
 same=m.block(manager,'var isCurrentSelection: Bool {')
 for invariant in ['!wasReset', 'active == mode', 'preferred == nil || preferred == mode', 'destination?.data == source.data']:
  assert invariant in same
 selected=m.block(manager,'func currentSelectionState()')
 for invariant in ['V3PlacedPairingDirectory', 'parse(content:', 'parsed.mode == active', 'persistedActiveProtocol == active', 'preferredProtocol == preferred', 'directory.read(name) == selected', 'source.data != selected.data']:
  assert invariant in selected
 assert not re.search(r'(isPairingReset|persistedActiveProtocol)\s*=(?!=)',selected)
 for forbidden in ['.write(', 'minimuxer', 'commitPlacedImport']:
  assert forbidden not in selected
 fast=m.block(life,'if alreadySelected && mayReuseTransport {')
 assert fast.index('try await verify()') < fast.index('try Task.checkCancellation()') < fast.index('try validateOperation()') < fast.index('try validate()') < fast.rindex('try validateCommitted()') < fast.index('if connectionVerified { return .ready }')
 assert 'try commit()' not in fast and 'try await start()' not in fast
 assert fast.count('try validateReusableTransport()')==2
 assert 'try commit()' in m.block(life,'if !alreadySelected {')
 wrapper=(r/'SideStore/SideStore/Core/DeviceApi/MinimuxerWrapper.swift').read_text()
 for anchor,native in [('func reinitializePairingData(', 'minimuxer.core.reinitializePairingData('),('func minimuxerStart(', 'minimuxer.core.start('),('func minimuxerStop(', 'minimuxer.core.stop(')]:
  body=m.block(wrapper,anchor)
  assert body.index('V3PairingTransportReceipt.shared.invalidate()') < body.index(native)
 start=m.block(wrapper,'func minimuxerStart(')
 assert start.index('try await minimuxer.core.start(pairingFile: pairingFile') < start.index('recordStarted(generation: startupGeneration,')
 assert 'contents: pairingFile, mode: minimuxerPairingProtocol()' in start
 receipt=m.block(wrapper,'final class V3PairingTransportReceipt: @unchecked Sendable {')
 for forbidden in ['UserDefaults', 'debugLog', 'print(', 'write(']: assert forbidden not in receipt
 for native in ['minimuxer.core.start(', 'minimuxer.core.stop(', 'minimuxer.core.reinitializePairingData(']:
  locations=[p for p in (r/'SideStore').rglob('*.swift') if '.ci' not in p.parts and native in p.read_text()]
  assert locations==[r/'SideStore/SideStore/Core/DeviceApi/MinimuxerWrapper.swift'], (native,locations)
 backend=m.block(service,'static func pairingUsePlaced(id: String)')
 for invariant in ['owner.requestID == id', 'owner.phase == .dispatched', 'current.requestID == owner.requestID', 'current.serviceInstanceID == owner.serviceInstanceID', 'current.phase == .dispatched']:
  assert invariant in backend
 assert '"pairingSelection": PairingFileManager.shared.currentSelectionState().rawValue' in service
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
 entry=m.block(view,'.task {')
 assert entry.index('selectionObserved = false') < entry.index('await status.reloadAndWait()') < entry.index('selectionObserved = outcome == .applied')
 assert 'message = ""' in entry and 'pairingUsePlaced' not in entry
 assert 'Device connection has not been checked on this screen.' in view
 presentation=m.block(ui,'enum V3PairingSelectionPresentation {')
 assert 'connected && observed && selection == "selected"' in presentation
 assert 'adoptedReady' not in presentation and 'Pairing file saved and selected.' in presentation
 outcomes=m.block(ui,'enum V3PlacedPairingPresentation {')
 assert 'Check VPN' not in outcomes
 for forbidden in ['print(plan.content)', 'debugLog(plan.content)', 'print(live)', 'debugLog(live)']:
  assert forbidden not in action
 with tempfile.TemporaryDirectory() as tmp:
  subprocess.run([sys.executable,str(here/'generate_fixture.py'),'--sources',str(r.resolve()),'--output',tmp],check=True)
  manifest=json.loads((Path(tmp)/'source-evidence.json').read_text())
  assert len(manifest['case_names'])==49 and len(set(manifest['case_names']))==49
 print('PLACED_PAIRING_STATIC_PASS')
if __name__=='__main__':main()
