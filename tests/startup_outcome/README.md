# Startup outcome regression contract

Run `python3 -B tests/startup_outcome/test_contract.py` from any working directory.
For macOS CI, set `REQUIRE_SWIFT_STARTUP_TESTS=1`; missing Swift is a failure.

The native fixtures compile the production finite outcome and the production
`DatabaseManager.start()` body, with a deterministic actor gate replacing Core
Data loading. They cover pending callbacks, delayed success, all allowlisted
failed-attempt outcomes, explicit retry and terminal outcome publication before
awaiters resume. They are not an iOS/Core Data database migration test.

Source checks verify that the existing storage-preservation guards retain their
conditions and local DatabaseError classifications, bootstrap diagnostics precede
journal/authentication/database access, and only bounded enum-derived records
cross the pre-readiness boundary. The existing maintenance-preservation suite
continues to exercise real temporary-directory layout cases.

No database, account, pairing, store path, error description or user-provided
string is included in startup logs. A failed attempt is not proof of permanent
data damage. The patch neither migrates nor deletes saved data.
