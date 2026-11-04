# Native recovery engine qualification

Run on macOS:

    python3 tests/database_recovery/run.py --output /tmp/recovery-report

This compiles the exact production `DatabaseRecovery.swift` and
`DatabaseRecoverySQLite.c`, without extracting or rewriting methods, together
with a synthetic SQLite validator. It creates no user data and touches no live
application containers. Unsupported hosts fail explicitly, never skip to PASS.
The report records all compiled source hashes and the compiler version.

The fixture exercises real committed WAL recovery, SQLite write reservations
before and after snapshot, separate-process writer exclusion, source writes
permitted after lease release and rejected on subsequent recovery, mutable
published database/Apps reopening, identical and differing candidate databases,
identical and differing Apps, source Apps changing before publication, malformed
receipts, database/Apps symlinks, orphan sidecars, a real unclosed rollback
journal, validator failure before publication, and a destination created during
validation that exclusive publication must preserve. Two interruption cases use
real child-process `_exit` calls, without production hooks: exit inside validation
before publication leaves staging unselected and a retry succeeds; exit immediately
after `resolve` returns leaves a committed generation that another process reopens.
A subsequent legacy commit after owner-process death must produce `sourceChanged`
without altering the committed destination or receipt. These process-exit tests do
not simulate power loss or a crash inside the atomic rename itself.

The rollback-journal case uses an actual interrupted SQLite write transaction;
the engine rejects the nonempty journal without attempting source recovery.
It does not claim every journal produced is hot under SQLite's recovery criteria.

The fixture validator is deliberately synthetic. This suite does not establish
Core Data model migration, physical iOS device behavior, app-group entitlement or
data-protection behavior, power-loss durability, or exclusion of legacy
filesystem-only Apps writers after the final inventory. Those need separate
qualification. The existing source lease also intentionally prevents another
new process from independently acquiring the same source writer reservation.

Portable checks:

    python3 -m unittest discover -s tests/database_recovery -p test_runner.py -v

These check runner/report contracts only and are not a native qualification pass.
The workflow runs only on pushes to `validation/issue56-preserving-recovery`.

## Qualification environment binding

The fixture canonicalizes only its owned temporary root before direct lease tests,
matching production root selection. `SQLITE_OPEN_NOFOLLOW` remains enabled; an
additional linked-ancestor negative must reject the open. Cases and SQLite failure
phases/codes are emitted without database paths or SQLite error-message content.

Both native runners derive the language mode from the actual SideStore target's
Release configuration through `plutil`. They record the declared setting, compiler
argument and project hash. This avoids compiling the production container under
an unrelated target's language mode. Reports bind all runner/helper/fixture inputs
and require unchanged source bytes before writing PASS to a fresh output directory.

Approved app-owned directory roots use POSIX `realpath` so Foundation cannot strip
`/private` and reintroduce an OS symlink rejected by SQLite `NOFOLLOW`. Existing
root leaves still cannot be symlinks. Missing optional paths are reconstructed
from an existing canonical ancestor without creation; permissions and non-directory
ancestors fail closed. Native negatives cover leaf aliases, inaccessible and invalid
ancestors, while approved ancestor aliases, equivalent roots and reset-lock
contention are tested. The finite Foundation/POSIX counterfactual remains in the
WAL relocation case and emits no paths.
