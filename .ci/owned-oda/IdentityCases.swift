import Foundation
@main struct IdentityCases {
 static func main() {
  let state = V3AuthIdentityStampState()
  let initial = state.snapshot
  let token = state.beginOwnedTransition(ifCurrent: initial.stamp)!
  precondition(!state.snapshot.stable)
  precondition(state.beginOwnedTransition(ifCurrent: initial.stamp) == nil)
  var writes = 0
  let accepted = state.commitDuringOwnedTransition(token) { writes += 1 }
  precondition(accepted && writes == 1)
  let adopted = state.completeOwnedTransition(token)
  precondition(adopted == state.snapshot.stamp && state.snapshot.stable)
  let staleCommit = state.commitDuringOwnedTransition(token) { writes += 100 }
  precondition(!staleCommit && writes == 1)
  let current = state.snapshot.stamp
  let interrupted = state.beginOwnedTransition(ifCurrent: current)!
  state.beginTransition() // concurrent signout/new identity invalidates reserved owner
  let interruptedCommit = state.commitDuringOwnedTransition(interrupted) { writes += 100 }
  precondition(!interruptedCommit && writes == 1)
  precondition(state.completeOwnedTransition(interrupted) == nil)
  precondition(!state.snapshot.stable)
  state.completeTransition()
  precondition(state.snapshot.stable)
  precondition(state.beginOwnedTransition(ifCurrent: current) == nil)
  let cancelToken = state.beginOwnedTransition(ifCurrent: state.snapshot.stamp)!
  enum Cancelled: Error { case cancelled }
  do {
   _ = try state.commitDuringOwnedTransition(cancelToken) { throw Cancelled.cancelled }
   fatalError("cancelled callback succeeded")
  } catch {}
  precondition(state.completeOwnedTransition(cancelToken) != nil)
  // Existing manual route semantics remain independent of new reservation API.
  let legacy = state.snapshot.stamp
  precondition(state.beginTransition(ifCurrent: legacy))
  precondition(!state.beginTransition(ifCurrent: legacy))
  state.completeTransition()
  precondition(state.snapshot.stable)
  print("PASS actual identity reservation: success, stale, signout overlap, cancel, legacy")
 }
}
