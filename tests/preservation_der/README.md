# Strict preservation DER decoder qualification

`run.sh` compiles the complete production decoder with 59 synthetic cases.
It does not authenticate CMS and explicitly reports `cms_verified:false`.
Run `python3 -B tests/preservation_der/test_contract.py` for source/fixture closure.

The decoder accepts complete authenticated XML and inner DER only. It preserves
raw bytes for freshness/duplicate identity checks. Normalized comparison retains
whole non-lifecycle dictionary pair TLVs, including original UTF8 key bytes;
only cross-bound UUID, CreationDate and ExpirationDate are excluded. TTL and
unknown supported authorization values are retained. Unsupported schema fails.

Public CMS test inputs are intentionally distributed Microsoft MSBuild fixtures,
pinned by commit, length and SHA256 in `public-fixtures.json`. The acquisition
helper refuses a destination inside this source tree. Runtime downloaded files
must be temporary, removed by the runner and excluded from all retained logs or
artifacts. Only booleans, test identities and counts may be emitted. Signature
math alone is not provisioning signer-role verification: public positive
qualification must use the actual production cryptographic facade before this
decoder, not a permissive OpenSSL subprocess or unverified CMS extraction.

Primary schema reference:
https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
The format is changeable; this deliberately supports a strict bounded subset.

`run_public.sh --openssl-root <same-run OpenSSL 3.5.9 install>` compiles the
actual C verifier, actual gateway Swift module, actual public Minimuxer facade
and this decoder. It checks compile-header and linked-library versions, uses no
synthetic-anchor define and validates a 16-case structured result. Public cases
cover both role signatures and complete binding for two profiles, corrupted
signatures, role confusion and cross-profile binding rejection. Downloaded
public bytes never leave the runner's temporary directory; the trap cleans it.
This runner still requires native macOS execution before being called qualified.

The XML data regression reproduces Swift Character CRLF grapheme behavior,
then checks LF/CR/CRLF/tab/space acceptance and NBSP/invalid alphabet/padding
rejection. Only ASCII Unicode scalars are removed; strict Base64 remains.
Primary references: https://developer.apple.com/documentation/swift/character/isnewline
and https://www.unicode.org/reports/tr29/ (GB3).

Foundation Base64 decoding alone is not canonical validation: the native test
observed acceptance of an extra '=' after an otherwise complete 40-character
encoding. Decoded bytes must re-encode to exactly the whitespace-stripped input.
Regressions retain the observed negative and cover unused padding bits, excess/
missing/interior padding, trailing garbage, truncation and valid 0/1/2 padding.
Canonical standard alphabet and zero-pad-bit reference:
https://www.rfc-editor.org/rfc/rfc4648.html#section-3.5
