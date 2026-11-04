# Confirmed initial provider rejection

`run.sh` generates and compiles complete SideSign authentication with offline transport/crypto doubles, then runs the original diagnostics/wire parity suite, 27 new producer cases, and actual SideStore retry mapper, authentication-phase wrapper/unwrapper and provider-sequence cases. No Apple account requests, real credentials, native provider, or Apple acceptance are tested.

Run with `SIDESIGN_ROOT=/path/to/SideSign bash .ci/initial-provider-rejection/run.sh`. Swift 6 is required. The generated source-evidence JSON hashes every included production input and generated Swift output; generation does not claim execution.

The separate owned ODA context/native suites remain required for lifecycle qualification. The integration source test checks task-group joining, captured context drainage, cancellation and identity ordering in the full operation; this fixture does not execute the entire UI operation or its database/keychain boundaries.

Only a source-created, context-bound error from the first owned On-Device authentication init request can enter the new `providerRejectedInit` transition. The existing explicitly selected finite plan, challenge latch, identity/commit checks, cleanup and backoff remain authoritative. Remote Mac wire policy and persistent provider preferences are unchanged.
