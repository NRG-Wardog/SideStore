# VPN transport recovery source regression

This fixture extracts the actual scanner, transport policy, interface observation
statements, unavailable-decision producer, MinimuxerError mapping, OperationError,
and finite readiness classifier. OS address/route storage is synthetic. It does
not start an emulator, device gateway, VPN, pairing or authentication.

The exact delivered policy and producer/observation excerpts are frozen with
SHA-256 and the original policy Git blob in `baseline-receipt.json`. They are
renamed during generation and executed against the same synthetic interfaces as
the candidate. The addressless/absent-interface case must reproduce the old
missing recovery reason and produce existing `noVPN`/`vpnUnavailable` after the
repair. Other transport results and messages must agree across all 144 inputs.

Run from a combined checkout containing `SideStore` and `LiveContainer`:

    VPN_TRANSPORT_SOURCE_ROOT="$PWD" REQUIRE_SWIFT_VPN_TRANSPORT_TESTS=1 \
      python3 SideStore/tests/vpn_transport_recovery/test_contract.py

The required mode fails if Swift is unavailable. Local generation/static checks
alone do not constitute Swift or Xcode runtime validation. The exported
`generate_source(root, include_operation_classifier=False)` composes this exact
producer chain with the host recovery fixture, without duplicate app symbols.

Scope: `fixtureReadiness` executes transport-unavailability production code,
not later live device readiness. Separate mapping negatives cover pairing,
unsupported backend, generic gateway noDevice and unproven VPN-drop strings.
