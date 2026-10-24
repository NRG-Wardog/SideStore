# SideStore runtime source ownership checkpoint

## Frozen identity and scope

- Upstream: `SideStore/SideStore`, commit `ff25922e5c13ccfafd83bda5092910d848ebd409`, tree `b015ff18eac594382beffd3780a231117573dc6b`.
- Builder reference: `NRG-Wardog/sidestore-auto-refresh` at `141776ba6ba38fc04a5e77f68b0cfc4e6c8842ee`.
- Destination: local `migration/runtime-source-141776ba` branch in the history-preserving `NRG-Wardog/SideStore` fork checkout. `origin` is the owner repository; `upstream` remains the original repository. Publication is separate.
- Final product/build-input parity: **628 files**, comprising **48 changed or generated files** and **580 unchanged upstream files**, with exact bytes and Git executable/symlink modes. Two child gitlinks remain unchanged.
- `Dependencies/SideSign`: `a731c0d5a9a6617c7b385ae493e07ffb7f81cd5d`.
- `Dependencies/minimuxer`: `98c3c79982f813878e922ab42f9545314a700f0c`.

The OLD prepared-source inventory contains 49 SideStore-owned differences. The additional file, `.combined-refresh-contract.json`, is an old patch preparation sidecar, **not runtime source**. Its exact hash and mode are recorded under `excluded_preparation_evidence` in the manifest, and its original bytes accompany the external migration evidence. It was staged with the refresh slice and removed in the final evidence-placement commit. It is absent from the maintained product tree and is never a build prerequisite. A comparator run with `--old-root` checks that excluded OLD evidence separately.

There are no product/build-input byte differences from the frozen OLD tree. New files are limited to the original MIT attribution and this read-only documentation/test/verifier set. No child repository was flattened, no dependency pin was advanced, and the package lock and Xcode project preserve the OLD prepared values, including their existing UI membership removals.

## Reviewable subsystem series

The eight runtime commits are deliberately interdependent and must be reviewed/applied as one completed series. No intermediate commit is represented as independently compilable. Final layout remains identical to OLD; this migration does not refactor the existing large `AppDelegate.swift` into new files.

1. Authentication: `AuthManager`, identity-bound developer portal calls, `SignInOperation`, 2FA policies, headless authentication state machine, transactional credential publication and account diagnostics.
2. Keychain/App Group: stored identifier/blob pair validation, shared migration/sign-out transactions, durable journals, shared App Group/process lock, secret handoff and account import/export.
3. Anisette adapters: provider snapshot reads and blob commits, headless server models, existing isolated-recovery implementation, finite native/Swift diagnostic trace and error classification.
4. Service/headless/IPC: bounded wire contract and cross-subsystem policies, command/service ownership, prompt and operation sessions, boot/database integration, headless handlers, URL routing and log privacy.
5. Certificate/provisioning: create/export adapters, durable active-certificate handling, signing/OCSP checks, profile acquisition, typed provisioning guidance and certificate operation adapters.
6. Refresh/background: completion verification, admission lease, refresh scheduling inputs, background run/result persistence, intent routing, pipeline execution and bounded console retention.
7. Transport integration: maintained backend connection configuration, minimuxer adapter, batch lease, original transport error propagation, pairing and SideJIT backend behavior.
8. UI/project membership: existing headless membership boundaries, Info.plist and exact frozen SwiftPM lock, legacy view adaptations.

`subsystem-mapping.json` records full commits, each modified path, original preparation stages and script/template hashes. It also records every contiguous final `AppDelegate.swift` insertion range and SHA-256, including shared cross-subsystem declarations assigned to the service slice. Shared wire, behavioral, App Group and handoff contracts retain their previous identical host/service representation; a coordinated cross-owner parity gate is required before activation. This checkpoint introduces no third copy or new independently evolving contract.

Upstream copyright headers, license files, history and unaffected files remain unchanged. `LICENSES/sidestore-auto-refresh-MIT.txt` is the exact original builder license at the integration baseline, retained for copied builder-authored implementation. This attribution records provenance; it does not assert a new legal compatibility conclusion.

## Read-only verification

Run from the fork root without generating bytecode in the product checkout:

```sh
python3 -B scripts/verify_runtime_source.py --require-clean
python3 -B scripts/verify_runtime_source.py --require-clean --old-root /path/to/frozen/prepared/SideStore
python3 -B -m unittest discover -s tests/runtime_source -v
```

The verifier checks all owner files, extra/missing paths, content, executable modes, symlinks, exact upstream ancestry/tree, unchanged child gitlinks and tracked inventory. `--require-clean` additionally rejects a dirty checkout. It never imports or runs builder patchers. The OLD comparator reads prepared input only; the manifest preserves upstream and final hashes, rather than regenerating product code.

Tests consume maintained Swift files directly. Portable tests cover exact whole-tree identity and structural contracts for credential/pair transactions, 2FA dispatch, identity revalidation, provider continuity, disabled recovery, finite diagnostics, App Group fail-closed storage, certificate persistence, transport leases, refresh ordering, project inputs and attribution. Adversarial verifier tests reject byte, mode, inventory and symlink drift, and distinguish OLD-only preparation evidence. Three optional Swift harnesses compile actual maintained declarations for 2FA, identifier/blob validation and finite trace behavior when `swiftc` is available. They do not substitute a Python policy model for Swift execution.

## Verification limits and preserved debt

This local checkpoint runs on Linux without Swift, clang, Xcode or an Apple SDK. Portable source/parity checks are not a full compile or runtime proof. The three Swift harnesses are explicitly skipped in this environment. iOS build/link, Security/Keychain/Core Data process behavior, real 2FA/Apple authentication, transport device operations, signing/provisioning, UI, entitlements and packaged artifact gates remain unrun here and must be established by the coordinated macOS/device pipeline.

The original source preparation replay was completed twice and recorded as idempotent in the frozen integration inventory. This fork does not run those transformers during its tests or builds. Historical builder patchers remain active and unretired pending end-to-end gates; active workflow/pin transition is outside this checkpoint.

- Automatic Anisette recovery remains disabled. Provider selection, identity, provisioning/reset policy and saved-blob handling are unchanged.
- The temporary finite Anisette trace remains enabled in the frozen baseline, including release-visible paths. Its `DEBUG TEMPORARY` label does not make it `#if DEBUG`-only.
- The known cleanup lifetime race is deliberately preserved, not fixed or certified safe by this migration.
- No claim is made that `nativeOTP/-45061` or the real-device sign-in incident has been fixed.
- No remote branch/default branch, release or tag is changed by this local series.
