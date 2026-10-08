# Explicit SideStore diagnostic dependency proof

This gate prepares a separately reviewed dependency transition over the published
ADI observer source checkpoint `364e65211f8678758542e3716e7b757c4dbd35ed`, tree
`e765c3d23c3299ec7e1e57ac31ad0a76a91ff658`. That checkpoint already contains the
reviewed observer delta from accepted production
`dd4f0ca36e8ef1d858548f583c65842a8fc0ced3`, tree
`b0c1d4f03785bbbf0d09b7329c0842a7a4d89d86`. It is immutable. The diagnostic
registry SHA256 is `97c9d0b81e9b59c8271ae1155393b2fcb534dc97ea367095d3adfcde8a3783ad`;
the accepted-to-diagnostic delta SHA256 is
`4d55fdeed931af02f9d44865c0c712695b471d8a101aa1643c3770484f158106`.

The dependency transition permits only:

- `.ci/production-dependencies.py`, this document, and
  `.ci/test_diagnostic_dependencies.py`;
- the exact reviewed `Dependencies/SideSign` gitlink;
- genuine resolver output for
  `AltStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Every other source, test, project, license, original parity proof, and historical
production receipt must match the observer checkpoint exactly. The minimuxer
gitlink remains `efbcab05d7d636aa37c6bf6c7f364d122c5610f6`; `.gitmodules` cannot
change. This gate does not add a framework or change runtime source.

## Preparation and exact source basis

Gate preparation alone leaves the SideSign gitlink and app lock unchanged. The
final published SideSign identity and genuine resolver output must arrive before
the dependency candidate can be completed. Do not invent a child SHA, tree,
origin hash, or candidate identity. No actual dependency basis accompanies a
gate-only preparation patch. Unit tests use isolated synthetic fixtures only.

After selecting and independently reviewing the actual published SideSign
dependency, commit the candidate and prepare the external source-only basis at
the integration's `dependencies/SideStore-basis.json` path. Use the exact CLI:

```sh
python3 -B .ci/production-dependencies.py --root /clean/SideStore \
  --diagnostic-basis /reviewed/dependencies/SideStore-basis.json \
  --diagnostic-basis-sha256 INDEPENDENTLY_APPROVED_SHA256
```

The strict basis has exactly these fields:

- `schema_version: 1`, `owner: "SideStore"`,
  `purpose: "diagnostic_dependency_source_transition"`;
- `source_registry_sha256` and `source_delta_sha256`, matching the immutable
  digests above;
- `accepted: { "commit": "dd4f0ca36e8ef1d858548f583c65842a8fc0ced3",
  "tree": "b0c1d4f03785bbbf0d09b7329c0842a7a4d89d86" }`;
- `source_checkpoint: { "commit": "364e65211f8678758542e3716e7b757c4dbd35ed",
  "tree": "e765c3d23c3299ec7e1e57ac31ad0a76a91ff658" }`;
- `candidate`, with the actual committed candidate's `commit` and `tree`;
- `anisette: { "repository": "https://github.com/NRG-Wardog/AnisetteKit.git",
  "accepted_commit": "62ce85c8798d8eab8e29752aba7dc9f1f6a5b80d",
  "diagnostic_commit": "e530b84687ebea2e7d1115119e1a6d18372de14b" }`;
- `sidesign`, with repository `https://github.com/NRG-Wardog/SideSign.git`, its
  actual final `commit`, `tree`, and independently reviewed `basis_sha256`;
- `changes`, an exact path map of changes from `source_checkpoint` to
  `candidate`, with `before` and `after` rows for each path.

Regular file rows are `{ "mode": "100644", "blob": "GIT_BLOB",
"sha256": "SHA256_OF_BYTES" }`. Gitlink rows are
`{ "mode": "160000", "commit": "EXACT_CHILD_COMMIT" }`. Newly added files
have `before: null`. The unchanged lock must not have a change row.

This gate verifies the SideSign gitlink against the approved tuple. The outer
graph proof must also verify the actual child checkout tree and independently
approved SideSign basis. The owner result explicitly reports this boundary;
declared child metadata does not replace child source verification.

The source basis never contains native/resolver status, tests, readiness, or
outcome receipts. Generating a digest is not approval. All metadata changes are
bound to reviewed exact bytes rather than broadly exempted. The default
production verifier and its frozen assertions retain their original behavior;
they intentionally reject the diagnostic owner tree.

## Actual Xcode resolution and separate evidence

Before resolution, the app lock must remain byte-identical to accepted production,
including its absent `originHash`. After actual resolution, only AnisetteKit may
move to the diagnostic revision; the other nine pins must retain every field.
Capture the lock exactly as written. Do not reformat it manually or fabricate,
remove, or substitute the observed origin metadata.

Commit only the genuine captured lock after the pending candidate. Do not change
gate, tests, docs, gitlink, or runtime source on the resolved-lock descendant.
Review a new external basis for its exact commit/tree and a separate
`dependencies/SideStore-resolver.json`. Supply both additional flags:

```sh
  --diagnostic-resolver-receipt /reviewed/dependencies/SideStore-resolver.json \
  --diagnostic-resolver-receipt-sha256 INDEPENDENTLY_APPROVED_RECEIPT_SHA256
```

The receipt has exactly: `schema_version: 1`, `owner: "SideStore"`,
`purpose: "diagnostic_xcode_resolution"`, actual GitHub Actions `run_url` and
positive `run_attempt`, pending `resolver_tested_commit` and
`resolver_tested_tree`, exact `lock_sha256`, `origin_hash` with Boolean `present`
and the actual `value` (null only when absent), `toolchain` with actual `xcode`
and `swift` versions, actual resolver `command` argument vector, and
`evidence_sha256` with `resolver_log`, `resolution_before`, and
`resolution_after` artifact digests. Review the actual artifacts independently.

The verifier requires the pending commit to be an ancestor of the resolved
candidate, its initial lock to equal accepted production, and every other
inventory entry to match the resolved candidate exactly. Receipt hashes and
observed lock/origin metadata must match. Synthetic fixtures are not native
receipts.

Both stages report `diagnostic_dependency_transition_pass` and
`production_ready: false`. Pending lock status is
`accepted_lock_retained_pending_resolution`; reviewed resolution reports
`reviewed_resolver_observed_lock` and `reviewed_diagnostic_resolution`.
Readiness remains `source_transition_only_requires_separate_native_receipt`.
Historical production receipts do not establish readiness for this graph.
Only the outer, separately reviewed new native receipt may establish it.

Run `.ci/test_diagnostic_dependencies.py` for adversarial coverage. Run the
unchanged original production tests against accepted-production fixture clones
loading the updated verifier, and original source parity at its frozen source
checkpoint. These portable checks never run Xcode or establish native success.
