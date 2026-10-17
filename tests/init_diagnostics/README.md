# Focused P0 initializer diagnostics

Run from either maintained repository, pointing to the other exact source checkout:

```sh
INIT_DIAGNOSTICS_PEER_ROOT=/path/to/other/repository \
INIT_DIAGNOSTICS_PRODUCER_ROOT=/path/to/reviewed/AnisetteKit \
  python3 -B -m unittest discover -s tests/init_diagnostics -v
```

Copied validation-runner tests also accept `SIDE_STORE_TEST_SOURCE` and
`MAINTAINED_LIVE_CONTAINER_TEST_SOURCE` (or `LIVE_CONTAINER_TEST_SOURCE`) as
checkout roots, plus `ANISETTE_KIT_TEST_SOURCE` for the native producer. Explicit
`INIT_DIAGNOSTICS_PEER_ROOT` / `INIT_DIAGNOSTICS_PRODUCER_ROOT` take precedence.
Keep all five files in this directory together when sealing a runner copy.

The source checks enforce shared parser, validator, error projection and all three
technical-detail renderers. A portable C++ fixture executes the actual native
formatter, including normalization; its exact output feeds Swift. With `swiftc`, the suite executes extracted maintained
Swift declarations, the actual SideStore error classifier, binary property-list
encoding/decoding, then an independently compiled `SideStoreSupport` host module
and the real importing UI renderer. External SDK error enums alone are doubles.
Both temporary-trace-enabled and disabled paths execute. Without Swift the
executable tests explicitly skip; source parity is not runtime evidence.

## Finite native contract

Only wrapper code -2 and this exact ordered canonical native message add fields:

```text
Library constructor execution failed [v1;kind=dt_init;reason=engine_error;engine=13;library=0;initializer=0]
```

The five keys are `native_init_kind`, `native_init_reason`, `native_init_engine`,
`native_init_library`, and `native_init_initializer`. They describe the primary
failure only. Probe code/phase/subcode stay in their existing fields; constructor
fields from a probe must never overwrite the primary tuple. `native_subcode`
remains independent and is `unknown` for constructor failures. The engine is a
Unicorn error scalar, never an ADI code, pointer, PC, W0 or register value.

- Kinds: unknown, dt_init, dt_init_array, array_entry_read
- Reasons: unknown, engine_error, unsupported_interrupt, unexpected_return,
  entry_read, invalid_vm, previously_failed
- Engine: -1 (unavailable) or 0...255
- Library and initializer ordinals: -1 (unavailable) or 0...65535
- unknown kind permits unknown/invalid_vm/previously_failed, all numbers -1
- dt_init and dt_init_array permit engine_error (engine nonzero or -1),
  unsupported_interrupt (any bounded engine), or unexpected_return (engine 0)
- dt_init requires initializer 0
- array_entry_read permits only entry_read (engine nonzero or -1)

The native producer normalizes unavailable data; consumers reject noncanonical,
partial, reordered, duplicate, extra, oversized, incoherent or out-of-range data.
Existing exact trace and ADI suffix handling runs before matching. Legacy exact
`Library constructor execution failed` gets setupConstructors with no fabricated
fields. Exact VM initialization and previously-failed restart-required literals
get setupVM and setupVMPreviouslyFailed. Unrecognized strings stay unknown.

The complete primary + attempt + probe + temporary trace + ADI context has 18
fields, below the unchanged 20-field limit and 4096-byte plist envelope. Tests
exercise this complete tuple and both boundary counts. Trace-disabled builds keep
the five constructor fields. No identity, authentication, recovery policy, VM
execution policy or reset behavior is changed.

## Limits

No physical-device or real Apple-library constructor execution is performed by
these tests. A real device run remains necessary to observe the original P0
failure's reason. The earlier vm.init.ok / library.load.ok / library.init.failed
trace suggests a constructor boundary; it does not establish the native cause.
These diagnostic changes are not a claimed fix for the constructor failure.
