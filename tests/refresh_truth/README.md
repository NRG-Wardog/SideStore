# Refresh truth qualification

Run `V3_REQUIRE_SWIFT=1 python3 -m unittest discover -s tests/refresh_truth -v` on macOS.
Without swiftc, the two runtime tests explicitly skip; portable checks are not native qualification.

The first native fixture extracts `V3RefreshVerification` from production and executes
22 deterministic cases using synthetic profile/certificate values. It does not decode
real CMS profiles or claim device acceptance. The second extracts the entire production
`RefreshAppOperation`, plus the actual Runner persistence block and persistence policy,
against inert CoreData/native-network boundaries. Its 18 cases exercise main/extension
selection, one invocation per profile, incomplete/lost acknowledgments, cancellation,
ownership expiry, unavailable observations, update/save failure, invalid identities and
expiry during a suspended baseline read. Four cases execute the actual nonself
InstallAppOperation admission/dispatch/readback fragment, with native installation stubbed. No real credentials, accounts or profiles are used.

Postconditions distinguish mutation dispatched from all required installations acknowledged.
A successful CopyAll query proves profile-store presence only, not which profile iOS selects
for a particular launch. Renewal compares the greatest prior matching profile lifetime
for each required identity, capped by the same validated certificate, against the minimum
new lifetime. Missing baseline, certificate change and unreadable snapshots remain unknown.

Direct session/journal and UI projections are qualified separately in the combined graph.
