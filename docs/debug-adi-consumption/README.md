# Temporary consumer decoder: diagnostic variant only

This local branch is separate from runtime-source parity migration. Its frozen parity manifest remains unchanged and will intentionally reject these runtime edits; do not weaken or regenerate that manifest to describe this branch as byte-identical parity. No dependency pin, release workflow, project graph or authentication algorithm is changed here.

Bases: SideStoredd4f0ca36e8ef1d858548f583c65842a8fc0ced3; LiveContainer47db163356dc419d2b6a894fdc5dbeb9d011dc69. The paired local Anisette observer ise530b84687ebea2e7d1115119e1a6d18372de14b. `contract-v1.json` binds its exact native header and Swift producer bytes and names the diagnostic-only variant.

## Data path

The actual native observer produces at most32 numeric rows within2048 bytes. The Anisette SDK validates them and appends a separate owned DEBUG suffix to its typed native error. SideStore strips that terminal suffix before the existing exact native phase classifier and existing native-stage trace parser. Only the finite decoded rows enter signingContext under `debug_temporary_adi_consumption`.

Both maintained owners contain the same public value-type decoder. LiveContainer's actual importing sign-in renderer appends `DEBUG TEMPORARY adi_consumption=...` to Technical Details/Copy Details. The field never replaces the error ID, native code, phase, correlation or ordinary recovery message. Target4 explicitly means untracked FD, including reuse before observation or tracking overflow; it is not an observed other path.

Invalid optional metadata is discarded without dropping valid main error fields. A single terminal suffix within8192 inspected bytes can be removed even when its body is invalid; duplicate markers or oversized whole descriptions remain unknown-phase while retaining the associated native code. No arbitrary description, path, token, blob, identifier, native buffer or hash enters the wire.

The existing4096-byte binary-plist failure cap stays unchanged. If this new field causes overflow, only its oldest rows are removed, retaining later rows and setting the explicit truncation bit. If even the empty marked field cannot fit, this optional field is omitted. Existing failures already too large without this observer retain their prior behavior; this change does not redesign the entire error envelope.

The existing `V3TemporaryAnisetteTrace.temporaryAnisetteTraceEnabled` switch disables consumer collection into the failure, wire retention and rendering. Metadata stripping still preserves normal phase classification. Observations are per-error values; no global storage or cross-attempt trace state is introduced.

## Validation and pending requirements

Run the focused suite with `ADI_CONSUMPTION_PEER_ROOT` pointing to the other isolated owner and `ADI_CONSUMPTION_PRODUCER_ROOT` pointing to the maintained Anisette diagnostic checkout:

`python3 -m unittest discover -s tests/adi_consumption -v`

The suite compiles the real C++ producer header to obtain its descriptor, checks its schema/ranges against the actual SDK and both owner decoders, and compares shared declarations byte-for-byte. When swiftc is available it executes extracted maintained capture/classification/wire code with external error type doubles, exercises canaries, malformed/oversized/duplicate metadata, pipeline errors, cancellation admission, correlation binding, disabled diagnostics and plist trimming. It also builds the actual LiveContainer common declarations as a separate SideStoreSupport module and compiles the actual importing host renderer against it. No alternate classifier is implemented in the tests.

Local Linux result: five tests discovered, three passed, two native Swift tests explicitly skipped because swiftc is unavailable. This is not a native compile or device-auth success claim. Required before integration: independent source review, Swift execution/cross-module checks, the user's migration checkpoint, a coordinated diagnostic-variant source manifest/pin review, then full required build/device gates. No publication or new IPA is authorized merely by these local test results.

The observer diagnoses native file consumption; it does not repair errno propagation, guest copying, blob identity, setup order or the known cleanup race. Those remain separate evidence-driven changes.

Production alignment: the SideStore debug commits were rebased onto the verified permanent dependency graph after parity IPA a939e4c passed. The three diagnostic owners remain local only; the other four production owners and the frozen registry are listed in contract-v1.json. A new diagnostic receipt must never borrow the old parity run as evidence for these runtime changes.

Event retention reserves16 setup rows and16 latest OTP rows. A tested40-setup/40-OTP sequence followed by an OTP read failure retains that failure with truncation explicitly set. Early setup cannot exhaust the OTP budget.


# Controlled staging-order experiment

The physical-device f9f23d98 result records an untruncated OTP-phase open of the expected adi.pb path and a successful 639-byte host read plus guest-memory copy, followed by nativeOTP -45061. This does not prove byte identity or cryptographic binding. No setup imported open/read was observed, which weakens a file-read caching explanation.

The separately maintained native candidate stages the unchanged supplied blob before common setup, retaining the current provider, UUID/path/Android-ID derivation, VM policy, mutex and single OTP invocation. Provisioning entry points and authoritative storage are not changed. This is a controlled experiment, not a proven authentication repair.

The v2 observer prefix adds only finite host-byte comparison and successful-copy input coverage. Comparison 0 is unavailable/unobserved, 1 means all compared host bytes match so far, 2 is a sticky mismatch. Coverage 1 requires comparison 1 and complete supplied-input comparison within one tracked sequential expected-file stream, with successful guest copies. Coverage does not establish EOF, total file length, blob validity or identity binding. Work is capped at 1 MiB per invocation; unknown offsets, tracking or budget loss remain incomplete. No raw bytes, paths, identifiers or hashes leave memory.

Both maintained consumers preserve v1 support, strict numeric parsing, 32 rows, 2048 encoded bytes and 4096 failure-wire bytes. Only optional diagnostic rows may be trimmed; the main failure and finite summary survive unchanged when they fit. Existing native code and phase classification remain intact.

Native producer and cross-module Swift validation are pending. The frozen contract-v1.json and accepted f9 receipts remain historical evidence.

The temporary failure-only legacy observation emits separate per-key missing/equal/different/ambiguous/unavailable statuses. It reads only existing entitled groups for the same service and two pair keys under the existing transaction lock, with selected snapshot checks before and after. It never chooses a legacy identity, probes it or writes it. Partial/conflicting groups are ambiguous; malformed/oversized values and stale/query failures are unavailable. UUID-only history remains explicit through a missing blob result. Diagnostic decoding is capped at 64 rows, 128 identifier bytes, 1,398,104 encoded blob bytes and 4 MiB aggregate bytes.


# Current P0 consumer compatibility contract (v3)

`contract-v3.json` is the maintained source contract used by
`tests/adi_consumption/test_contract.py` in both SideStore and LiveContainer.
`contract-v1.json` and `contract-v2.json` remain byte-for-byte historical originals;
the successor checks their SHA-256 values rather than rewriting old receipts.
The earlier sections describe the historical ADI-only stages. The independent
constructor-fault wire below has its own finite contract.

## Maintained owners and source inputs

The actual maintained owners are:

- SideStore: `AltStore/AppDelegate.swift`, this contract, and
  `tests/adi_consumption/test_contract.py`.
- LiveContainer: `SideStoreSupport/SideStore.swift`, this contract, and
  `tests/adi_consumption/test_contract.py`, plus the actual importing renderer in
  `LiveContainerSwiftUI/Views/V3UnifiedShell.swift`.
- AnisetteKit supplies the producer inputs; it does not own another copy of this
  consumer contract. All four exact inputs are pinned: `Sources/AnisetteDataProvider.swift`,
  `Native/Loader/adi_consumption_debug.h`, `Native/Loader/vm_initialization_diagnostics.h`,
  and that constructor header's transitive `Native/Loader/bounded_fault_diagnostics.h`.

These candidates start from SideStore `9d90c9db20a5b07bd4a34254efb596fbc7c04616`
(tree prefix `f67804f8`), LiveContainer `545438e1f0a89fdef375f73273c5c9fc2735cbce`
(tree prefix `e8014dd`), and AnisetteKit `227dfd8c8456cd62e4ceff4971b17afb2003d7e8`
(tree prefix `4d31646c`). These identify archive origins, not newly published
commits or built artifacts. The successor's individual producer-input hashes bind
the actual checked local candidate, including any reviewed header repair.

The old v2 Swift producer pin is
`9c55c035d640cae8c2b6ac173db9f118a4e49cce789c0dba24f4cffca58476de`.
The current producer Swift pin is
`2b3913be77f019de3f0520e8ea8fcdad1a1b4a638c2493e84d063f07f813e855`.
The ADI producer header remains
`077b377c87b201893f83afbff5a4dd37e01354253f08045a3831adcb50022346`.
The four exact candidate input hashes are recorded in `contract-v3.json`.

## Current producer suffix proof

Source checks read the pinned current producer file, including all three real
response parser declarations. Each removes `v3_constructor_fault` before returning
successful data and retains the original primary error when throwing. The exact
suffix order for headers is constructor fault, native trace, then ADI consumption.
Start/end provisioning append constructor fault then native trace. This proves the
current source composition; it is not Swift execution evidence.

The optional constructor-fault body is `v1;p0_fault_diag1` followed by six bounded,
canonical integers and two loaded-asset SHA-256 digests. Digests are either `-` or
exactly 64 lowercase hexadecimal characters. The body is at most 255 bytes. Raw
addresses, register values, guest strings, identities and filenames are excluded.
`contract-v3.json` records all ranges, unavailable states and cross-field coherence.
The existing ordered constructor reason/engine description is not changed by this
wire. Its consumer context key is `native_constructor_fault`.

The successor preserves ADI v1/v2 support, numeric ranges, 32-row/2048-byte bounds,
comparison/coverage meaning, and the 4096-byte failure-plist envelope. The owner
checks require the ADI bounding step before the constructor-fault bounding step;
they do not relax the pre-existing wire cap or main-error assertions. Focused
constructor compatibility execution belongs to `tests/init_diagnostics` and is
not replaced by source-contract assertions.

Run the maintained suite from each owner with both roots provided:

```sh
ADI_CONSUMPTION_PEER_ROOT=/path/to/other/owner \
ADI_CONSUMPTION_PRODUCER_ROOT=/path/to/AnisetteKit \
  python3 -B -m unittest discover -s tests/adi_consumption -v
```

Source and portable C++ checks can run on a host without `swiftc`. Existing Swift
execution cases report unavailable runtime explicitly; no new skip is introduced
by the successor. Source parity and producer pins cannot establish an Apple build,
cross-module Swift execution, physical-device behavior, authentication success or
release readiness. No old accepted receipt is reused for this candidate.

The pinned constructor header now includes the two explicit empty snapshot
defaults from pending local AnisetteKit candidate
`7ebbb4ce0ce5756fe9d7bfe1899aaaa358c8b1e2`, tree
`9fa391fa6486a08e2d3db96b0fc9b1c0b372fb65`, whose sole parent is the archive
base above. This is local preparation only, not an approved remote identity.
The constructor header hash changes from
`0fbe1ac033f2d2dbe7f3c5fbd0cade277f8e7eb51529264dfec3ca75279ba862` to
`95e683f69fea4a2723ee748dd71f05bc6ec50bfdce4277e7181948e600e2b39f`.
The bounded-fault transitive header remains
`416729f9cc73ba05ec5164af2f5d7928f86db2d72e6ddb83863e5433c36d3eaa`.
