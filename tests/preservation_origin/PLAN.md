# Exact-profile origin integration test contract

Status: source fixtures implemented; local static controls pass. Native execution pending; no account/network/device execution.
The new route must not widen the static signer-pin facade or create a signer cache.

## Layers and honest boundaries

1. Existing `preservation_refresh` extraction compiles actual fetch, state,
   refresh, DER/XML decoder and admission guards. SDK models/portal/device/CMS
   are explicit boundary doubles. It proves control flow and no-mutation order,
   not platform TLS or cryptographic validity.
2. New origin composition fixture must compile the actual SideSign bounded
   transport/result validator/private receipt factory and actual SS receipt
   consumer. A test-only compile seam supplies synthetic HTTP responses at the
   transport edge. It must not expose a production receipt initializer, accept
   caller-created trusted receipts, or reimplement the validator in a double.
3. Actual minimuxer C inspection tests separately establish strict signature,
   chain, current time, algorithm, attribute and SID checks. Inspection content
   is explicitly untrusted until exact-profile origin evidence is conjoined.
4. Native composition later must prove production package/API linkage. Local
   source checks or fake HTTP do not prove live Apple/free-account availability.

## Mandatory positive paths

- Unknown static pin, cryptographically valid installed CMS, unique exact UUID
  from fresh read-only listing, exact profile-ID download and identical CMS:
  installed capability minted for this operation/account/team/session only.
- Existing-ID candidate generation occurs only after installed corroboration;
  candidate must have its own exact-response capability, never the old receipt.
- Fresh installed readback and candidate revalidation retain exact byte and
  operation binding, then one profile injection; app/extension identity and
  unrelated metadata remain unchanged.
- Static approved-pin installed profiles need no read-only corroboration. Candidate generation still uses its own hardened operation response.
- Multiple matching installed profiles require independent exact-byte evidence;
  one receipt cannot authorize another profile using the same signer leaf.

## Mandatory negative boundaries

Before candidate generation: unsupported free endpoint, list denial/error,
empty list, duplicate UUID, ambiguous portal ID, wrong app/team, wrong returned
UUID/ID, downloaded body mismatch, same UUID with changed body, redirect/non-200,
wrong final endpoint, response overflow, deadline, expired/cancelled operation,
owner/team/session drift after every await, failed outer CMS, failed/expired
inner crypto, incomplete/mismatched inner-to-outer binding.

Before injection: candidate own evidence absent/mismatched/replayed, candidate
same leaf but unrelated profile, candidate expired/not extended or authorization
changed, fresh inventory drift, caller cancellation or ownership change during
corroboration/generation/readback, operation receipt reused in another operation.
Body-bitflip must never be accepted through provenance even when UUID/leaf match.

All negative outcomes assert zero app registration/capability/group/sign/remove
calls. Pre-generation negatives assert zero generation; later negatives assert
zero injection. Lost ACK stays one dispatch without replay or expiry bookkeeping.

## Receipt non-forgeability and harness closure

- Compile-negative fixture attempts public receipt construction and must fail.
- Test transport seam is conditional compilation only, absent from production
  interfaces and normal builds; it cannot return preconstructed trust receipts.
- Exact source inputs, fixture files, ordered case IDs and counts are hash bound.
- Logs contain finite test IDs/counts only; synthetic bytes never carry owner data.

## Frozen native inventories (pending execution)

- `run.sh`: 4 static controls, 58 actual-transport/consumer runtime cases and
  3 external compile-negative visibility cases; Swift 6 explicitly selected.
- `../preservation_refresh/run.sh`: 55 policy and 64 integration cases
  (45 previous + 19 origin flow cases); SDK transport/crypto boundaries mocked.
- Exact ordered identities live in each `expected-cases.json`.
- Expired-session and cancellation cases do **not** prove the 180-second
  operation deadline timer. No wall-clock-expiry execution claim is made.
- Fake HTTP exercises request/stream/redirect boundaries, not platform TLS.
