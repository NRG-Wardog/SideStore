"""Source guards; these do not claim Swift execution or device proof."""
from pathlib import Path
import argparse


def validate(root):
    text = (root / 'SideStore/Core/Operations/PipelineRunner.swift').read_text()
    lane = text.split('// V3_PROFILE_TRANSACTION_LANE_BEGIN\n')[1].split('// V3_PROFILE_TRANSACTION_LANE_END')[0]
    body = text.split('    func performOperation(for operation:')[1].split('    private func performPipeline(')[0]
    expected = ['let transactionAdmission = V3RemoteRequestLeases.admitted',
                'var profileTransaction: V3ProfileTransactionLane.Ticket?',
                'defer {\n            if let profileTransaction { V3ProfileTransactionLane.shared.release(profileTransaction) }',
                'try transactionAdmission?.check()', 'try refreshAdmission?()',
                '!group.progress.isCancelled', 'transactionProgress?.isCancelled != true', 'let transactionProgress = progress.progress(for: operation)',
                'try checkTransactionAdmission()\n            profileTransaction = try await V3ProfileTransactionLane.shared.acquire()',
                'try checkTransactionAdmission()\n            group.setVerification']
    for item in expected:
        assert item in body, item
    assert body.index('defer {') < body.index('        do {') < body.index('shared.acquire()') < body.index('self.performPipeline(') < body.index('try dbContext.save()') < body.index('group.set(.success(result)') < body.index('        } catch {')
    assert 'refreshAdmission: checkTransactionAdmission, readProfiles: readProfiles)' in body
    pipeline = text.split('    private func performPipeline(', 1)[1]
    assert 'context.profileMutationAdmission = refreshAdmission' in pipeline
    assert 'refreshAdmission: refreshAdmission' in pipeline
    refresh = (root / 'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text()
    after_dispatch = refresh.split('            preservationMutationDispatched = true', 1)[1].split('    private func ', 1)[0]
    assert 'try refreshAdmission?()' not in after_dispatch, 'Do not gate post-dispatch accounting on progress cancellation'
    assert body.index('let transactionProgress =') < body.index('shared.acquire()')
    assert body.count('shared.acquire()') == 1 and body.count('shared.release(') == 1
    assert 'if case .refresh' not in body
    assert 'static let shared = V3ProfileTransactionLane()' in lane
    assert 'withTaskCancellationHandler' in lane and 'queue.removeAll { $0 === ticket }' in lane
    assert 'catch { release(ticket); throw error }' in lane
    assert 'guard owner === ticket, ticket.state == .granted else' in lane
    scheduler = text.split('let normalOperations = operations.filter')[1].split('// Outer entry wrappers')[0]
    assert scheduler.index('while let _ = try await taskGroup.next() {}') < scheduler.index('for operation in hostOperations')
    assert scheduler.count('self.performOperation(') == 2
    # No pipeline step may recursively acquire the non-reentrant lane.
    for path in (root / 'SideStore/Core/Operations').rglob('*.swift'):
        if path.name != 'PipelineRunner.swift':
            assert 'performOperation(for:' not in path.read_text(), str(path)
    return len(expected) + 15

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    print(f'{validate(args.repo)} serialization source guards passed; Swift/device not executed')
