# Preservation-only refresh qualification

Run `bash tests/preservation_refresh/run.sh` on the native qualification runner.

The generator extracts the **actual** production `PreservedProfilePolicy`, the exact fetch-preserving helper, the complete Refresh operation, registry, and CacheResignedMetadata's early-return prefix. It does not substitute a parallel policy implementation. Foundation/CoreData/SideSign/portal/native installation boundaries are inert doubles. Existing-ID profile generation is represented as a portal mutation; no registration, feature/group update, signing, removal or app replacement boundary is exposed to the extracted helper.

Expected terminal outputs are JSON with exact ordered case identities in `expected-cases.json`: 55 pure-policy cases and 98 fetch→refresh integration cases. `run.sh` rejects missing/extra/truncated output. The generator emits input hashes, not execution success.

Integration covers unchanged legacy identity without an original app cache, extension metadata preservation, changed authorization/snapshot rejection, stale DB identity rebind after suspension, contradictory certificate serial/team/history, unavailable/ambiguous existing portal IDs, cancellation and lost ACK without replay/bookkeeping. Successful metadata processing executes the actual early return; reaching its remaining write/sweep path deliberately fails the fixture.

This qualifies control flow, not a real portal/iOS profile parser, app signature, Keychain/App Group access or device refresh. No real credentials, profile contents, identifiers or network operations are used. Actual full iOS build and matching native execution remain separate required gates.

Normal active-certificate installation may leave the DB override serial nil; the positive integration case preserves this absence while requiring verified signer DER and rejecting contradictory nonnil serials.

Historical profiles supply restrictive constraints, not candidate provenance. The 98 integration cases include exact fresh candidate provenance, old-inventory byte/multiplicity preservation, new UUID/add-only behavior, no replay, XML-only compatibility when DER is absent, and rejection of malformed present DER. The historical-case reconciliation maps all 64 prior integration identities to retained or explicitly superseded checks. The refresh harness doubles the origin SDK; `preservation_origin/run.sh` separately extracts the actual transport/mint/consumer for 58 transport cases and 3 negative visibility checks. Neither source generation nor Python contract passes establish Swift compilation or native execution.


Portal-identity coverage keeps the exact match guard and tests strict lookup failures, empty/missing/case-only/duplicate matches, preserved cancellation and original unknown errors, and scoped finite diagnostics. Response parsing itself is separately exercised by the SideSign strict App-ID lookup fixture. No account or identity mutation is a recovery fallback.
