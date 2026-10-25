# Diagnostic provider sequence contract (#51, #52)

## Current implementation boundary

The host has an ordered provider selection and a Foundation-only transition
policy. The existing single-provider sign-in remains unchanged. The sequence
controls appear only when a credentials prompt advertises exactly
`diagnosticProviderSequence = isolated-signin-sequence-v1` and a nonempty,
duplicate-free `diagnosticProviders` list containing supported IDs.

The matching SideStore service adapter is implemented in the issue-51 candidate.
It advertises Remote Mac and, only when the user's persisted default is already
the configured remote-server route, Configured Remote Server. Native On-Device
cancellation cannot yet be bounded, so ODA remains manual only. Remote identity
contexts are independently owned and invalidated before an explicit transition.
Global provider settings are not changed. The configured server route attempts
only its selected URL, not the existing URL acquisition failover list. It retains
its own existing local ADI pair/cache and may commit a validated fresh blob through
the existing snapshot guard; this is namespace separation from Remote Mac, not a
new temporary cache per attempt. It does not consume the remote Mac context.
The selected route remains task-local throughout provisioning. Before committing
credentials, the service atomically verifies/reserves the captured account stamp
and rejects a changed local provider default.
Source agreement and portable tests do not prove device sign-in acceptance.

The host returns the exact capability plus `diagnosticProviderOrder`, a comma
separated subset in the user's chosen order. It does not store credentials or
change global provider settings. With the toggle off it preserves the existing
`anisetteProvider = remoteMac` submit-v2 behavior. Every new prompt resets the
selection; no implicit consent carries to another session.

## Service adapter contract

- Validate the advertised capability and ordered subset again at the service
  boundary, before accepting the credentials answer.
- Execute provider acquisition and Apple authentication within one owned
  session. Do not implement this by replaying host `authBegin` requests.
- Use an explicit attempt context for each provider, with independent identity,
  Anisette state and request cancellation. Do not overwrite global defaults to
  select a provider. Existing server URL failover is not a full sign-in attempt.
- Keep credentials in memory only for the bounded sequence. Release them at
  terminal completion, cancellation, or session expiry. Never include them in
  results, trace fields, or descriptions.
- Stop immediately at successful Apple authentication. Provisioning failure
  must never trigger provider rotation after credentials/session commit.
- Classify errors from typed evidence. No configured
  servers, provider HTTP 5xx and explicit invalid-Anisette rejection are eligible.
  Network failures after Apple authentication begins are eligible only for
  known preconnection errors. A timeout after an Apple request starts has an
  uncertain account outcome and stops instead of replaying credentials. The
  configured-server timeout also stops rather than rotating. Unknown errors,
  credential errors, rate limiting, restrictions and identity/storage errors
  stop the sequence.
- Use monotonic time. An active attempt has a 60-second budget; a 2FA prompt
  suspends that budget while awaiting the user. The existing session deadline
  still limits overall lifetime. After a challenge has been shown, never rotate
  to another provider, even if a later request fails transiently.
- On timeout/cancellation, cancel the underlying network and operation work.
  Join it before continuing. A timeout event is not proof that it stopped. Structured task-group scope
  joins cancelled work before returning. If a native/provider call ignores
  cancellation, no next provider starts; the outer auth-session watchdog owns
  the terminal timeout. The provider result shows "Deadline exceeded; waiting
  for cleanup" while draining. This implementation cannot force-stop arbitrary native
  work and does not claim a hard wall-clock bound on that join.
- Before allowing the next attempt, supply explicit evidence that the previous
  task stopped, its context was invalidated, cached state is isolated and no
  credentials were committed. An uncertain result must stop, not retry.
- Backoff is 2 seconds before the second provider and 4 before the third.
  Each configured provider runs at most once. Ignore stale attempt callbacks.
- Report only bounded provider IDs and typed result categories in the session
  snapshot. Present results without URLs, Apple IDs, tokens or raw errors.

The shared seam is `V3DiagnosticProviderPlan` and
`V3DiagnosticProviderSequence`, separate from the large SwiftUI shell. Maintain
matching service semantics through contract tests rather than expanding
upstream-facing UI patches.

## Verification

`python -B -m unittest discover -s tests -p test_diagnostic_provider_sequence.py -v`
executes the production policy with Swift when installed. Missing Swift is an
explicit skip, not a behavioral pass. The harness covers ordered first/later
success, exhaustion, timeout, cancellation, backoff, duplicate submit, stale
completion, cache/commit rejection and 2FA stop behavior. Full target compilation,
service integration and physical-device tests remain necessary.
