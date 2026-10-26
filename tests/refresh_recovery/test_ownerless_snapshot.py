"""Interrupted-refresh snapshot regression. No account/device mutations.
Native case executes extracted production lease and snapshot policy; the persisted
run record is a synthetic fixture, not an actual App Group database/journal.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'AltStore/AppDelegate.swift'

def definition(source, name):
    start = source.index(name + ' {')
    end = source.index('\n}\n', start) + 3
    return source[start:end]

class OwnerlessSnapshotTests(unittest.TestCase):
    def test_snapshot_separates_activity_from_recovery_fence(self):
        source = APP.read_text()
        snapshot = source.split('private func snapshot() throws -> [String: Any] {', 1)[1]
        self.assertLess(snapshot.index('refreshAdmission.restoreLost'), snapshot.index('let activeMutation'))
        activity = snapshot.split('let activeMutation =', 1)[1].split('let provisioningState', 1)[0]
        self.assertIn('refreshAdmission.hasLiveOwner', activity)
        self.assertNotIn('refreshAdmission.isActive', activity)
        busy = snapshot.split('var response:', 1)[1].split('"activeMutation":', 1)[0]
        self.assertIn('refreshAdmission.isActive', busy)
        self.assertIn('operationRecovery != nil', busy)
        self.assertIn('"refreshRecovery"] = ["runID": operationRecovery.sessionID, "ownerLost": true]', snapshot)
        receive = source.split('private func receive(_ data:', 1)[1].split('private func run(', 1)[0]
        self.assertIn('refreshAdmission.restoreLost(runID: recoveryRecord.sessionID)', receive)
        self.assertIn('refreshActive: refreshAdmission.isActive', receive)
        reconcile = source.split('case "refreshAdmissionReconcile":', 1)[1].split('case "appIcon":', 1)[0]
        self.assertIn('refreshAdmission.ownerLost', reconcile)
        self.assertIn('reconcileRefreshAdmissionAfterDeviceCheck', reconcile)

    def test_host_mirror_when_supplied(self):
        root = os.environ.get('LIVE_CONTAINER_SOURCE_ROOT')
        if not root:
            self.skipTest('Explicit host source root not supplied')
        host = (Path(root) / 'SideStoreSupport/SideStore.swift').read_text()
        for name in ('struct V3RefreshAdmissionLease', 'enum V3RecoveryOnlySnapshotPolicy'):
            self.assertEqual(definition(APP.read_text(), name), definition(host, name))

    def test_host_admission_uses_exact_recovery_policy_without_bypassing_authority(self):
        root = os.environ.get('LIVE_CONTAINER_SOURCE_ROOT')
        if not root:
            self.skipTest('Explicit host source root not supplied')
        host = (Path(root) / 'SideStoreSupport/SideStore.swift').read_text()
        method = host.split('public func statusReplyMayApply(_ reply:', 1)[1].split(
            'public func statusReplyMayApplyRecoveryEvidence', 1)[0]
        self.assertIn('let ticket = reply["_v3StatusAuthorityTicket"] as? V3StatusWriteTicket', method)
        self.assertIn('V3WireContract.strictBool(reply["activeMutation"]) == false else { return false }', method)
        self.assertIn('V3RecoveryOnlySnapshotPolicy.mayApplyFullStatus(', method)
        self.assertIn('activeMutation: V3WireContract.strictBool(reply["activeMutation"]) == true', method)
        self.assertIn('recoveryHold: V3WireContract.strictBool(reply["recoveryHold"]) == true', method)
        self.assertIn('reply["refreshRecovery"] != nil', method)
        self.assertIn('busyValue = typedBusy && !recoveryOnly', method)
        self.assertIn('return V3StatusReplyCommitPolicy.mayApply(ticket, authority: statusWriteAuthority,', method)
        self.assertIn('currentServiceEpoch: statusWriteAuthority.serviceEpoch', method)
        self.assertIn('currentServiceInstanceID: currentStatusServiceInstanceID', method)
        self.assertIn('busySnapshot: busyValue == true)', method)

    def test_native_relaunch_and_repeated_snapshot_session(self):
        compiler = shutil.which('swiftc')
        if not compiler:
            if os.environ.get('REQUIRE_SWIFT_REFRESH_RECOVERY_TESTS') == '1':
                self.fail('Swift required for interrupted-refresh ownership qualification')
            self.skipTest('Swift unavailable; native production-model case must run in CI')
        source = APP.read_text()
        swift = 'import Foundation\n' + definition(source, 'struct V3RefreshAdmissionLease')
        swift += '\n' + definition(source, 'enum V3RecoveryOnlySnapshotPolicy')
        swift += r'''
func check(_ value: Bool, _ label: String) { precondition(value, label) }
let run = "6E6E645A-1A87-4EBF-A96A-344A73EF914E"
let request = "026C01FB-9424-417B-843A-4188AA685289"
let other = "2C540A40-A749-4076-963A-6CC0C3595B2F"
let url = URL(fileURLWithPath: CommandLine.arguments[2])
var lease = V3RefreshAdmissionLease()
if CommandLine.arguments[1] == "before-exit" {
    check(lease.acquire(runID: run, requestID: request, authenticationActive: false,
          anotherMutationActive: false, now: Date(timeIntervalSince1970: 100)), "live admission")
    check(lease.isActive && lease.hasLiveOwner && !lease.ownerLost, "live owner visible")
    let data = try PropertyListSerialization.data(fromPropertyList: ["runID": run, "kind": "refreshAll"], format: .binary, options: 0)
    try data.write(to: url)
    print("PASS before-exit retained uncertain synthetic record")
} else {
    let bytes = try Data(contentsOf: url)
    let record = try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: String]
    check(record["kind"] == "refreshAll", "exact retained record")
    // New process has no in-memory owner. This is the receive/readiness path.
    check(lease.restoreLost(runID: record["runID"]!), "restore persisted owner-loss")
    for _ in 0..<8 {
        check(lease.isActive && lease.ownerLost && !lease.hasLiveOwner, "hold is not execution")
        check(V3RecoveryOnlySnapshotPolicy.mayApplyFullStatus(busy: lease.isActive,
              activeMutation: lease.hasLiveOwner, recoveryHold: true,
              hasTypedRecoveryEvidence: true), "repeated UI snapshot may apply")
        check(!lease.acquire(runID: other, requestID: request, authenticationActive: false,
              anotherMutationActive: false), "new mutation stays fenced")
        check(!lease.reconcileAfterDeviceCheck(runID: run, userConfirmed: false), "no automatic reconciliation")
        check(!lease.reconcileAfterDeviceCheck(runID: other, userConfirmed: true), "wrong owner cannot release")
        check(try Data(contentsOf: url) == bytes, "observation never deletes or modifies durable evidence")
    }
    check(!V3RecoveryOnlySnapshotPolicy.mayApplyFullStatus(busy: true, activeMutation: true,
          recoveryHold: true, hasTypedRecoveryEvidence: true), "another active owner still refuses full status")
    check(lease.reconcileAfterDeviceCheck(runID: run, userConfirmed: true), "exact explicit confirmation")
    check(!lease.isActive && !lease.hasLiveOwner, "only confirmed owner released")
    check(lease.acquire(runID: other, requestID: request, authenticationActive: false,
          anotherMutationActive: false, now: Date(timeIntervalSince1970: 100)), "fresh owner admitted only afterwards")
    check(lease.expire(now: Date(timeIntervalSince1970: 100 + V3RefreshAdmissionLease.lifetime)), "expired owner")
    check(lease.isActive && lease.ownerLost && !lease.hasLiveOwner, "expiry retains mutation fence but not live activity")
    print("PASS new-process readiness then eight same-session recovery snapshots; no implicit mutation or journal deletion")
}
'''
        with tempfile.TemporaryDirectory(prefix='refresh-recovery-') as tmp:
            p = Path(tmp).resolve()
            (p / 'main.swift').write_text(swift)
            subprocess.run([compiler, str(p / 'main.swift'), '-o', str(p / 'fixture')], check=True)
            for mode in ['before-exit', 'after-relaunch']:
                subprocess.run([str(p / 'fixture'), mode, str(p / 'record.plist')], check=True, timeout=30)

if __name__ == '__main__':
    unittest.main(verbosity=2)
