# Production dependency transition candidate

This commit prepares source-owned dependency wiring over an exact reviewed
source checkpoint. Runtime and license blobs remain identical. No authfix,
logging change, runtime generator, integration workflow, release, or tag is part
of this change. It is not a successfully resolved or natively tested build.

## Exact graph

- SideSign's manifest and lock select
  `https://github.com/NRG-Wardog/AnisetteKit.git` at
  `62ce85c8798d8eab8e29752aba7dc9f1f6a5b80d`, with no branch constraint.
- SideStore's Xcode lock selects the same AnisetteKit revision.
- SideStore's submodule URLs select `NRG-Wardog/SideSign.git` and
  `NRG-Wardog/minimuxer.git`. No branch hint can override committed gitlinks.
  The candidate must not be used for a production build while its SideSign
  child pin is null in `.ci/production-dependencies.json`.
- The intended minimuxer child is
  `efbcab05d7d636aa37c6bf6c7f364d122c5610f6`. It already consumes its locally
  built IDevice framework. idevice `0182d7d8ce0c8bbeb440adbc989d88dc1d4c0789`
  and jktcp `82277a1f366e8d92e775d14212ff21621b25f3f3` retain their existing
  sibling source layout and Cargo wiring; this candidate does not change them.
- All five unrelated SideSign lock pins and all nine unrelated SideStore lock
  pins remain identical, including URLs, revisions and branch/version states.

## Lock metadata is provisional

Both locks keep schema version 3 and remove the old `originHash`. Keeping the
old hash would misrepresent the new manifest graph; no new hash was guessed.
SwiftPM's [resolved-store implementation](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageGraph/ResolvedPackagesStore.swift)
models this value as optional. That source inspection is not evidence that the
selected Xcode/Swift resolver accepted these candidate locks.

Real resolution on the target macOS/Xcode toolchain is mandatory. Record its
version, complete command and output, lock before/after hashes, exact checkout
origins/revisions, and resolved dependency graph. Preserve the resolver-produced
hash in a separately reviewed metadata commit. Update only this gate's lock
metadata assertion and the exact lock digest to match that observed result;
never relax the pin-map comparison. Fail resolution if any unrelated pin moves.

## Verification layers

The frozen source proof files and manifests are unchanged. They still describe
the original prepared source checkpoint exactly. Their old whole-tree commands
correctly reject the production tree's intentional metadata transition.

1. Run the original frozen parity command from an independent, full-history
   checkout at the exact `source_checkpoint` recorded here. Preserve its result.
   SideSign: `python3 -B .ci/source-parity.py`.
   SideStore: `python3 -B scripts/verify_runtime_source.py --require-clean`.
2. Run `python3 -B .ci/production-dependencies.py` on a clean production checkout.
   It binds the complete tracked inventory and every unchanged checkpoint blob
   and mode, verifies working files/index, and checks exact dependency pins.
   It rejects GIT environment redirection, hidden working edits and arbitrary
   source exemptions. It does not execute a resolver or claim runtime success.
3. While the child commit is unpublished, SideStore preparation can be reviewed
   with `python3 -B .ci/production-dependencies.py --allow-pending-child-pins`.
   That explicit mode reports preparation only. The default fails closed.
4. Run `python3 -B .ci/test_production_dependencies.py`. These mutation tests
   cover source drift, unsafe file types, hidden changes, unexpected files,
   index redirection, allowlist broadening, unrelated pin movement, floating
   Anisette branches, duplicate identities and fabricated hashes.
5. On SideStore run `python3 -B tests/runtime_source/test_runtime_source.py`.
   Only the two whole-tree assertions and the intended Anisette pin assertion
   are adapted for the intentional dependency transition. The two frozen
   whole-owner adversarial fixtures explicitly check out the frozen checkpoint
   before mutation, preserving their original rejection assertions. All other
   verifier adversarial tests and native declaration/behavior tests still run. Swift compiler absence is a skip, never native success.

The integration's seven-owner contract gate must still verify all 88 frozen
contract-bearing source files and 22 edges against the exact selected owners.
Its original frozen registry/provenance remains evidence for the checkpoint;
production provenance separately records this narrow dependency transition.
No wildcard source exclusions or rebaselined runtime hashes are appropriate.

## Publication and native acceptance order

1. Resolve and test the local SideSign candidate on the target macOS toolchain
   against the published AnisetteKit commit, using its real remote URL. Use
   `swift package resolve` in an isolated candidate copy and fail on unrelated
   pin drift. Do not use path overlays, package mirrors or source patchers.
   Run the existing SideSign native test suite and iOS compiler/build checks
   against this exact manifest and resolved graph; capture all failures.
2. Commit the actual resolver metadata and its narrow proof update locally.
   Publish only when separately authorized and verify that exact child SHA can
   be fetched from `NRG-Wardog/SideSign`. No default branch move is implied.
3. In SideStore finalize both gitlinks atomically: published SideSign commit
   and the exact minimuxer commit above. Record the SideSign SHA in the proof,
   then run the strict gate. Initialize children from their committed URLs;
   verify their heads, origins, retained histories and licenses.
4. Build the pinned Rust/framework outputs from maintained idevice/jktcp sources
   with the already-reviewed build process. Stage only build products where
   minimuxer already expects them; do not rewrite package/runtime sources.
5. Resolve SideStore's actual Xcode project graph using the target toolchain,
   with no local-path overlay. Preserve all nine unrelated frozen pins. Record
   and commit the real lock metadata and narrow proof digest update separately.
6. Run all portable tests plus actual native SideStore behavior/compiler tests
   and the full seven-owner contract gate. Existing native skips must become
   executed tests on the selected Mac runner. Verify the maintained production
   checkout, not just a frozen or overlaid scratch copy.
7. Run the combined IPA build from the seven exact production owner commits.
   Verify runtime source hashes before build and tracked-source immutability
   afterward, preserve artifact/provenance hashes, inspect packaging/signing and
   symbol/marker acceptance. Store generated products outside source checkouts
   where possible. If tools create expected build outputs inside them, use a
   separate clean checkout for the strict whole-tree proof; do not add broad
   ignored-path exemptions to this verifier.

Native resolution, compiler execution, the combined IPA and device behavior
remain required gates. This local candidate does not establish those results.
