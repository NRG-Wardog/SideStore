# Preserving startup recovery for issue 56

This change addresses the previously blocked private-to-shared database layout
and equivalent duplicate layouts. It is not evidence that the original reporter's
specific installation has been repaired. Do not close the issue solely because
source tests or a clean install pass.

## Invariants

- A single existing shared database retains its filename. No unnecessary relocation
  is performed. Fresh installation does not create a database in the selector.
- Private stores, duplicate store names, or private Apps data enter a recovery gate
  before normal Core Data loading. Both legacy/current names and WAL/SHM/journal
  sidecars are inventoried. Orphan sidecars, symlinks, nonregular files, nonempty
  rollback journals, and external-data support directories fail closed.
- Every retained candidate receives a SQLite `BEGIN IMMEDIATE` write reservation,
  before it is inspected through SQLite. Reservations live as long as the selected
  recovered store is used. A second SideStore recovery process cannot bypass a busy
  source; it must retry after the owner exits. This deliberately favors preservation
  over multi-process database access.
- SQLite's backup API obtains a consistent snapshot including committed WAL rows.
  Raw database/WAL copies are never used. Normalized standalone snapshots are
  conservatively compared byte-for-byte. Different snapshots are not merged or
  selected by time, size, store UUID, or filename. Equivalent content may still
  conservatively fail comparison if SQLite physical layout differs.
- App trees are copied and verified with per-path file digests and permission bits.
  Different overlaps fail. Originals remain. App caches, certificates and payloads
  are selected from the recovered Apps root together with the recovered database.
- Schema migration, compatibility validation, and a read-only materialization of
  each entity happen only on the owned staging copy. Existing source models and
  mappings are found through the owning bundle.
- The complete database, Apps tree and receipt are flushed and atomically published
  with an exclusive directory rename. A partial/stale staging directory is never
  selected. An already existing final directory is never overwritten.
- On restart, original write reservations are reacquired before source snapshots
  and Apps inventories are compared with the receipt. Legitimate writes to the
  recovered database and Apps do not invalidate the receipt. Changed originals,
  a replaced store UUID, or an invalid receipt stop startup without overwriting data.
- Explicit same-process startup retries retain their existing source reservations.
  The legacy delete/reset API refuses recovery generations, including before the
  database attaches, because it cannot safely rewrite the recovery ownership graph.
- No maintenance counter is advanced; no account, pairing, anisette, certificate,
  or signing state is reset. The legacy App Group migration preference is retained.

## Boundaries

A SQLite write reservation does not serialize filesystem-only legacy Apps edits.
Pre/post inventories reject observed edits and originals are retained, but strict
whole-installation quiescence cannot be claimed for an independently running old
binary. Reopening the old version after process exit can also create divergence;
that is detected on the next startup, never merged automatically.

Genuinely divergent databases or app files remain a deliberate blocked state.
Automatic selection would risk discarding unique records. Supporting user-directed
selection/merge requires a separate reviewed recovery UI and authorization model.
No claim is made that arbitrary corrupt stores or unrecognized schemas are repairable.

Recovery can require temporary space for the database and app tree. Failed attempts
remove only their own staging directory while the process is alive. A hard process
termination may retain an ignored staging directory; no automatic broad cleanup of
potential recovery material is performed.

`fsync` plus atomic exclusive rename protects process-interruption publication.
This is not a claim of power-loss durability on every iOS filesystem/device.
Physical app-group entitlement, data-protection, startup timing on large libraries,
and affected-device upgrade behavior still require the full IPA/device gates.

## Qualification

- `tests/database_recovery`: native exact-engine SQLite/filesystem/concurrency and
  interruption cases. Synthetic validation callback; does not claim Core Data.
- `tests/database_recovery_coredata`: compiles the entire production
  `PersistentContainer.swift`, exact recovery engine and original model resources.
  v17.6 DELETE and committed-WAL fixtures must migrate to v17.7 while preserving
  Account/Team/InstalledApp/InstalledExtension attributes and relationships.
  Generic managed-object fixture classes avoid executing account/keychain code.
- `tests/upstream_sync/test_maintenance_preservation.py`: existing portable
  preservation/model controls with the startup integration contract updated.
- `.github/workflows/database-recovery.yml`: isolated validation branch only,
  pinned actions, macOS/Xcode matching the main qualification toolchain.

Native execution is mandatory; an unsupported host exits nonzero with NOT RUN.
Do not treat portable runner/source tests as native or device qualification.
