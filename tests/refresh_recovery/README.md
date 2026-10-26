# Interrupted refresh status recovery

The durable refresh admission remains a mutation fence after process death or
lease expiry. It is not a live operation owner. Readiness requests restore this
ownerless record before the first UI snapshot; subsequent snapshots must expose
`activeMutation=false` when no other owner exists, while retaining `busy`,
`recoveryHold`, and the exact refresh recovery record.

Run `LIVE_CONTAINER_SOURCE_ROOT=/absolute/LiveContainer REQUIRE_SWIFT_REFRESH_RECOVERY_TESTS=1 python3 tests/refresh_recovery/test_ownerless_snapshot.py` on macOS.

The native case compiles extracted production lease and recovery-snapshot policy,
writes a synthetic durable run fixture in one process, and starts a fresh process
to simulate readiness restoration and eight repeated UI observations. It verifies
new mutations remain blocked and only exact, explicitly confirmed reconciliation
releases the owner. This does not execute actual iOS force-quit, App Group journal
I/O, device installation, or transport recovery. Those remain separate evidence.
