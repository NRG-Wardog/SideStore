# Explicit legacy replacement admission

`python3 -B tests/legacy_replacement/test_contract.py`

This extracts the actual production immutable binding, admission policy and
assessment coordinator. External Core Data, certificate store, source hash and
wire-decoder objects are explicitly inert doubles, not installed-signature proof.
The actual canonical wire parser is qualified separately in the host wire suite.

There are 42 native assertions. Three independently compiled counterfactuals must
fail when nonce consumption, stale snapshot equality or consent validation is
removed. `REQUIRE_NATIVE_LEGACY_REPLACEMENT=1` makes compiler absence a failure.
Portable execution does not establish native compilation or physical installation.

Preparation performs local reads only. Consent is required before a new, known
operation session; no successful sibling target is retried. Current installed
keychain/AppGroup access is unknown and preservation is never promised. No backup,
uninstall, account reset, certificate rotation or profile mutation occurs here.
