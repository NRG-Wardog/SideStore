#!/usr/bin/env python3
"""Source-owned startup outcome checks. Native extracted-production tests require Swift."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / 'AltStore/Core/Model/DatabaseManager/DatabaseManager.swift'
APP = ROOT / 'AltStore/AppDelegate.swift'
MAINTENANCE = ROOT / 'SideStore/MaintenanceManager.swift'
CAUSES = ('databaseLayoutBlocked', 'databaseLayoutConflict', 'databaseAppGroupUnavailable',
          'databasePersistenceFailed', 'databaseStartupFailed')

class StartupContract(unittest.TestCase):
    def test_typed_guards_preserve_original_failures(self):
        text = MAINTENANCE.read_text().split('public func performMaintenanceIfNeeded')[0]
        self.assertEqual(text.count('throw V3DatabaseStartupGuardFailure('), 6)
        for cause, count in [('databaseLayoutBlocked', 2), ('databaseLayoutConflict', 2),
                             ('databaseAppGroupUnavailable', 1), ('databaseStartupFailed', 1)]:
            self.assertEqual(text.count('cause: .' + cause + ','), count)
        self.assertIn('underlying: DatabaseError.missingAppGroup', text)
        self.assertEqual(text.count('underlying: DatabaseError.migrationFailed'), 5)
        for forbidden in ['moveItem(', 'removeItem(', 'copyItem(', 'destroyPersistentStore']:
            self.assertNotIn(forbidden, text)

    def test_outcome_only_finite_data(self):
        text = DB.read_text().split('struct V3DatabaseStartupOutcome:')[1].split('// V3_DATABASE_STARTUP_OUTCOME_END')[0]
        for forbidden in ['Error', 'NSError', 'URL', 'localizedDescription', 'userInfo', 'Date', 'UUID']:
            self.assertNotIn(forbidden, text)
        self.assertIn('events.count > 16', text)
        self.assertIn('private(set) var events', text)

    def test_bootstrap_before_auth_and_journal(self):
        text = APP.read_text().split('private func receive(_ data:')[1].split('enum ServiceError:')[0]
        bootstrap = text.index('// V3_BOOTSTRAP_READINESS_DIAGNOSTICS_V1')
        self.assertLess(text.index('V3WireContract.decodeRequest'), bootstrap)
        self.assertLess(text.index('matchesInFlight'), bootstrap)
        self.assertLess(bootstrap, text.index('V3OperationRecoveryJournal.currentState()'))
        block = text[bootstrap:text.index('let mutation = !V3WireContract.readOperations')]
        self.assertIn('operation == "logTail"', block)
        self.assertIn('"tail": startup.logTail', block)
        self.assertIn('retryable: false, safeCause: safeCause', block)
        for forbidden in ['viewContext', 'V3OperationRecoveryJournal', 'V3HeadlessRuntime', 'underlying:', 'debugLog']:
            self.assertNotIn(forbidden, block)

    def test_pending_not_terminal_or_false_success(self):
        text = APP.read_text().split('// V3_BOOTSTRAP_READINESS_DIAGNOSTICS_V1')[1].split('let mutation =')[0]
        self.assertIn('if let cause = startup.failure', text)
        self.assertIn('code: .notReady, id: id, retryable: operation == "snapshot"', text)
        self.assertNotIn('"ready": true', text)
        self.assertEqual(text.count('response["operationNotDispatched"] = true'), 2)

    def test_owning_task_settles_before_error_reaches_awaiters(self):
        text = DB.read_text().split('public func start() async throws')[1].split('private func performStart')[0]
        self.assertEqual(text.count('self.startTask = nil'), 1)
        self.assertLess(text.index('self._startupOutcome.fail(cause)'), text.index('self.startTask = nil'))
        self.assertLess(text.index('self.startTask = nil'), text.index('throw error'))
        self.assertTrue(text.rstrip().endswith('try await task.value\n    }'))
        self.assertIn('if let startTask { return startTask }', text)
        self.assertIn('throw guarded.underlying', text)

    def test_success_and_phase_classification_are_actual_completion(self):
        text = DB.read_text()
        self.assertLess(text.index('try await self.performStart()'), text.index('self._startupOutcome.transition(.ready)'))
        self.assertIn('self._startupOutcome.phase == .loadingStore ? .databasePersistenceFailed : .databaseStartupFailed', text)
        self.assertLess(text.index('transition(.loadingStore)'), text.index('try await self.persistentContainer.loadPersistentStores()'))
        self.assertLess(text.index('transition(.preparingDatabase)'), text.index('try await self.prepareDatabase()'))

    def test_no_raw_boot_error_log(self):
        text = APP.read_text().split('debugLog("Starting DatabaseManager...")')[1].split('// V3_HEADLESS_IMAGE_PIPELINE')[0]
        self.assertNotIn('\\(error)', text)
        self.assertIn('sanitized startup diagnostics', text)

    def test_native_production_outcome(self):
        compiler = shutil.which('swiftc')
        if not compiler:
            if os.environ.get('REQUIRE_SWIFT_STARTUP_TESTS') == '1':
                self.fail('Swift compiler required for startup outcome qualification')
            self.skipTest('Swift unavailable; extracted-production runtime coverage deferred to macOS CI')
        source = DB.read_text()
        enum = source.split('enum V3DatabaseStartupFailure:')[1].split('// Preserve existing local')[0]
        model = source.split('struct V3DatabaseStartupOutcome:')[1].split('// V3_DATABASE_STARTUP_OUTCOME_END')[0]
        swift = 'import Foundation\nenum V3DatabaseStartupFailure:' + enum + '\nstruct V3DatabaseStartupOutcome:' + model
        swift += r'''
func check(_ value: Bool, _ label: String) { if !value { fatalError(label) } }
var state = V3DatabaseStartupOutcome()
check(state.failure == nil && state.phase == .waiting, "genuine no-callback remains pending")
state.transition(.selectingStore)
state.transition(.loadingStore)
check(state.failure == nil && state.phase == .loadingStore, "delayed load remains pending")
state.transition(.preparingDatabase)
state.transition(.ready)
check(state.failure == nil && state.phase == .ready, "only observed completion ready")
for cause in V3DatabaseStartupFailure.allCases {
    state.transition(.selectingStore)
    state.fail(cause)
    check(state.failure == cause && state.phase == .failed, "exact typed failure")
    check(state.logTail.contains("database_startup_cause=" + cause.rawValue), "failure log accessible")
}
for _ in 0..<100 { state.transition(.selectingStore); state.fail(.databasePersistenceFailed) }
check(state.events.count <= 16 && state.logTail.utf8.count < 2048, "bounded records")
check(!state.logTail.contains("/private/") && !state.logTail.contains("@"), "finite enum records only")
state.transition(.selectingStore)
check(state.failure == nil, "explicit new attempt clears prior outcome")
state.transition(.ready)
check(state.failure == nil && state.phase == .ready, "recovered explicit attempt")
print("startup outcome actual production state: PASS")
'''
        with tempfile.TemporaryDirectory(prefix='startup-outcome-') as temporary:
            root = Path(temporary).resolve()
            path = root / 'main.swift'; path.write_text(swift)
            binary = root / 'startup'
            subprocess.run([compiler, str(path), '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=15)

    def test_native_actual_start_lifecycle(self):
        compiler = shutil.which('swiftc')
        if not compiler:
            if os.environ.get('REQUIRE_SWIFT_STARTUP_TESTS') == '1':
                self.fail('Swift compiler required for actual startup lifecycle')
            self.skipTest('Swift unavailable; actual startup lifecycle deferred to macOS CI')
        source = DB.read_text()
        enum = source.split('enum V3DatabaseStartupFailure:')[1].split('// Preserve existing local')[0]
        model = source.split('struct V3DatabaseStartupOutcome:')[1].split('// V3_DATABASE_STARTUP_OUTCOME_END')[0]
        start = source.split('    public func start() async throws')[1].split('    private func performStart()')[0]
        swift = 'import Foundation\nenum V3DatabaseStartupFailure:' + enum + '\nstruct V3DatabaseStartupOutcome:' + model
        swift += """
struct V3DatabaseStartupGuardFailure: Error { let cause: V3DatabaseStartupFailure; var underlying: Error { cause } }
actor Gate {
    var released = false
    var rawFailure = false
    var arrived = false
    var failure: V3DatabaseStartupFailure?
    var entry: CheckedContinuation<Void, Never>?
    var release: CheckedContinuation<Void, Never>?
    func awaitEntry() async { if !arrived { await withCheckedContinuation { entry = $0 } } }
    func wait() async {
        arrived = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { release = $0 } }
    }
    func open(_ cause: V3DatabaseStartupFailure?) { failure = cause; released = true; release?.resume(); release = nil }
    func openRawFailure() { rawFailure = true; open(nil) }
    func result() throws {
        if rawFailure { throw NSError(domain: "PRIVATE_ACCOUNT_SENTINEL", code: 9,
            userInfo: [NSLocalizedDescriptionKey: "/private/db/account@example.test SECRET_SENTINEL"]) }
        if let failure { throw V3DatabaseStartupGuardFailure(cause: failure) }
    }
}
final class Probe: @unchecked Sendable {
    let lock = NSLock()
    var _isStarted = false
    var _startupOutcome = V3DatabaseStartupOutcome()
    var startTask: Task<Void, Error>?
    let gate: Gate
    init(_ gate: Gate) { self.gate = gate }
    var isStarted: Bool { lock.withLock { _isStarted } }
    var outcome: V3DatabaseStartupOutcome { lock.withLock { _startupOutcome } }
    func performStart() async throws {
        lock.withLock { _startupOutcome.transition(.loadingStore) }
        await gate.wait()
        try await gate.result()
    }
    public func start() async throws
""" + start + """
}
@main struct Main {
    static func check(_ value: Bool, _ label: String) { if !value { fatalError(label) } }
    static func main() async throws {
        for cause in V3DatabaseStartupFailure.allCases {
            let gate = Gate(); let probe = Probe(gate)
            let owner = Task { try await probe.start() }
            await gate.awaitEntry()
            check(!probe.isStarted && probe.outcome.failure == nil, "pending callback not failure or success")
            await gate.open(cause)
            do { try await owner.value; fatalError("expected actual failed start") } catch {
                check(error is V3DatabaseStartupFailure, "original typed local error preserved, wrapper not leaked")
            }
            check(!probe.isStarted && probe.outcome.failure == cause, "terminal outcome before awaiting caller returns")
            check(probe.lock.withLock { probe.startTask == nil }, "owning failure released task")
            await gate.open(nil)
            try await probe.start()
            check(probe.isStarted && probe.outcome.phase == .ready && probe.outcome.failure == nil, "explicit retry succeeds")
            try await probe.start()
            check(probe.outcome.phase == .ready, "idempotent started path")
        }
        let gate = Gate(); let probe = Probe(gate)
        let owner = Task { try await probe.start() }
        await gate.awaitEntry()
        check(probe.outcome.phase == .loadingStore && probe.outcome.failure == nil, "genuine missing callback remains pending")
        await gate.open(nil)
        try await owner.value
        check(probe.isStarted && probe.outcome.phase == .ready, "delayed success actual start")
        let failedGate = Gate(); let failedProbe = Probe(failedGate)
        let failedOwner = Task { try await failedProbe.start() }
        await failedGate.awaitEntry(); await failedGate.openRawFailure()
        do { try await failedOwner.value; fatalError("expected persistence failure") } catch {}
        check(failedProbe.outcome.failure == .databasePersistenceFailed, "observed load failure classified by phase")
        check(!failedProbe.outcome.logTail.contains("SENTINEL") &&
              !failedProbe.outcome.logTail.contains("@") && !failedProbe.outcome.logTail.contains("/private/"),
              "raw description, domain, account and path absent from bootstrap log")
        print("actual production startup task lifecycle: PASS")
    }
}
"""
        with tempfile.TemporaryDirectory(prefix='startup-lifecycle-') as temporary:
            root = Path(temporary).resolve()
            path = root / 'main.swift'; path.write_text(swift)
            binary = root / 'startup'
            subprocess.run([compiler, '-parse-as-library', str(path), '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=20)

if __name__ == '__main__': unittest.main()
