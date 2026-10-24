# Temporary full login trace

Run from either owner checkout:

    LOGIN_TRACE_PEER_ROOT=/path/to/other/owner LOGIN_TRACE_PRODUCER_ROOT=/path/to/AnisetteKit python3 -B -m unittest discover -s tests/login_trace -v

One random per-login correlation ID joins the operation, credentials UI wait/submission,
keychain snapshot/pair validation/blob presence, request headers, provider/native stages,
Apple authentication/2FA, credential/session commit, provisioning, account save/finalization
and cleanup. Stage rows only carry enum ordinals, bounded elapsed/duration milliseconds,
finite error categories and permitted numeric codes. No provider text, account identifiers,
passwords, 2FA codes, tokens, headers, paths, blob bytes or device identifiers are accepted.
The stage ordinal order is defined in AnisetteKit/Sources/LoginDiagnosticTrace.swift;
this wire version accepts stages 0...56 and build marker login_trace_v1.

SideStore retains its trace across queued operation execution and binds it with TaskLocal.
The headless sign-in session owns the same trace; only its validated snapshot crosses into
LiveContainer failure diagnostics. Each snapshot is capped at 2048 bytes. The unchanged
20-field context and 4096-byte failure wire caps remain enforced; oldest login rows are
removed first and loss is marked explicitly. Original native/error evidence is preserved.
Session timeout adds a typed timeout failure envelope while preserving the original
state, authentication/resumable flags, user message and prior portal failure. The terminal
observer is retained in the ring even after the console cap, and reaches Copy Diagnostics.
LiveContainer keeps timeout diagnostics separately from retry/action facts, validates the
4096-byte envelope and matching session, and clears the diagnostic on new attempts or session
replacements. Retiring the same terminal session to nil retains its copyable trace. Real host tests compile the shared failure decoder and UI retention/renderer policy.
Success and cancellation still have no Copy Diagnostics trace payload. Console output stops
after 128 event lines and an explicit truncation marker; later events stay in the in-memory
ring and are exported through a failure/retry envelope.

The tests compare the maintained mirrored parser/validator/renderers and stage numbering,
check operation binding and retained identity/recovery guards, and execute the actual Swift
parser/wire on hosts with swiftc. Absence of Swift is an explicit skip, not a runtime pass.
No Apple login, native guest execution, physical-device validation or recovery policy change
is performed. This is instrumentation, not a fix for the original initializer failure.
