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
