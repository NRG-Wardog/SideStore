# Remote identity reuse regression

This package reads the selected candidate's production bytes, rather than a saved implementation.
Use a combined input root containing `SideStore` and `LiveContainer`; the acquired
SideSign checkout must be at `SideStore/Dependencies/SideSign`. Baseline is the previously delivered source tree, not a generated model.
Inputs must be real files, not symlinks. The generator refuses missing/duplicate source anchors.

Generate only:

```sh
python3 SideStore/.ci/remote-identity-reuse/generate_fixture.py \
  --candidate-root /path/to/candidate \
  --baseline-root /path/to/delivered-baseline \
  --output /path/to/output
```

Run on a matching macOS Swift host:

```sh
bash SideStore/.ci/remote-identity-reuse/run.sh \
  --candidate-root /path/to/candidate \
  --baseline-root /path/to/delivered-baseline \
  --output /path/to/output
```

The fixture compiles actual protected-record validation/CAS/read-back, Security adapter
query/get/set/remove methods, remote-identity Keychain adapter, credential transaction and
journal bodies, sign-out method and transaction override implementation. The default
Security calls initializer is redirected to an injected fake. Every Security callback is
in-memory; the native lock fallback deliberately throws. Account storage is a synthetic
boundary, not an independent implementation of identity persistence.

The runtime portion extracts the actual SideSign context/profile/state, SideStore provider
identity owner and lease code, AuthManager session/coalescer path, DeveloperPortalProxy
bound-session/dispatch methods, accountScopedRead, PipelineRunner's complete detached
entry plus route wrapper, AppManager's outer refresh queue, and the unchanged
BackgroundRefreshAppsOperation callback/continuation method. The remote client, old local provider, team database, portal API
and heavy pipeline work are inert boundaries. One documented wait is inserted immediately
inside each real tested Task.detached body to reproduce queue/account-change races deterministically.
Remote URLSession is replaced only by an inert session type. There is no copied identity,
authorization, lease or queue implementation.

Cases cover restart reuse, credential-route/account separation, concurrent CAS, normal
sign-out retaining the provider identity, explicit reset, preservation of old local/Android
data, provider/access-group separation, stale/malformed/oversized records, secure query
attributes, storage failures and read-back, and diagnostics redaction. They also cover
pending-token quarantine, losing first provisioners, cancellation, cached-data revocation,
account replacement, reset races, explicit portal dispatch and existing background refresh.
An unmarked legacy token route requires one fresh manual sign-in, even when old local data
exists; a verified local marker restores ordinary configured local continuation afterward.
Narrow source checks also verify both terminal handoffs, selected-route credential commits,
headless admission, outer sync/background queue entries, callback-after-scope ordering, and
the scoped profile/app-ID coalescers. Runtime refresh cases count callbacks synchronously
and close the inherited owner immediately in completion, rejecting duplicate publication.
Those additional wiring checks are not
execution of the full onboarding or headless driver pipeline.
Source and support
hashes, extraction spans, baseline feature gaps and projection changes are recorded in
`source-evidence.json`. Runtime evidence is produced only after compiling and running.
The binary requires `--cases-output PATH` and writes schema
`remote-identity-reuse-cases-v1`, lowercase `status: pass`, exact unique `cases` and
`case_count`, `fake_only: true`, and all network/native-provider/native-Keychain flags false.

The baseline lacks this feature, so it receives explicit source-gap assertions rather than
a fabricated baseline implementation/runtime failure. This does not replace application
compilation, real macOS Security integration, cross-process locking or physical-device QA.
No network, authentication, provisioning, pairing, native provider, actual Keychain writes,
or real credentials are allowed. All example account and token values are invented.
