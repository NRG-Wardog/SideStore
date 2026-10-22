# Refresh failure boundary regression

Run `python3 -m unittest discover -s tests/refresh_failure -v`.
For standalone runtime validation, set `REQUIRE_SWIFT_REFRESH_FAILURE_TESTS=1`
so a missing compiler fails. The comprehensive diagnostics gate instead imports
`generate_source(root)` from `test_contract.py` into its existing wire-copy suite,
then explicitly generates, compiles, and executes that single fixture. The helper
returns `(source, inputs_path_map)`; paths are exact source-owned inputs, not copied
production implementations. Generation-only receipts are not runtime evidence.

The runtime fixture extracts the maintained boundary mapping, AppOperation case
routing, entire AppManager error mapper, NSError title wrapper, CombinedFailure
capture, finite wire validation, and binary-plist round trip.
It covers every new boundary, an unrelated step, unknown private native domains,
known numeric domains, preserved typed failures and native markers, cancellation,
and rejection of mismatched correlation IDs. External SDK enum identities and
inert app/database interface shells are test doubles; error-routing and
diagnostic behavior are not. No network, device, auth, or vendor library runs.

Source checks tie the boundary helper to the actual profile-injection and local
record-update instructions, preserve cleanup/cancellation, and verify the existing
NSError title-mapping path copies diagnostic markers. These source checks do not
prove iOS compilation or a physical-device refresh.

Certificate portal tests extract the actual `portalCertificates()` call sequence
and its boundary helper. Inert provider shells independently throw at session,
team, and certificate fetch, checking ordered short-circuit, finite stage/source,
redaction, success, cancellation, and preservation of typed failures. This is a
separate certificate-list observation path, not proof of any refresh root cause.
