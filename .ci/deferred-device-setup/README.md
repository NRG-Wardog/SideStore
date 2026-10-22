# Deferred device setup fixture

This isolated offline fixture projects the production provisioning loop, successful/failing finalization, deferred identity validation and pairing-configuration observation unchanged. The shared allowlisted outcome policy is byte-checked across service, host and UI. It never authenticates, uses native providers, reads real pairing files or contacts the network.

Generate: python3 -B generate.py --sources ASSEMBLED_ROOT --output-dir OUTPUT
Source checks: python3 -B test_source.py --sources ASSEMBLED_ROOT
Native fake fixture: swiftc -parse-as-library OUTPUT/CandidateDeferredSetup.swift OUTPUT/BoundaryDoubles.swift OUTPUT/RuntimeTests.swift -o OUTPUT/fixture; OUTPUT/fixture OUTPUT/cases.json

Only side-effect boundaries are doubles: account/team/certificate acquisition, Keychain/private-key proof, checked Core Data save, file/bundle metadata, device registration, resign and UI completion. The real transaction remains protected by structural assertions; this fixture does not establish Core Data durability, cryptographic proof, complete backend/UI execution, UIKit compilation, device operation, or real pairing correctness. Matching native compilation and physical-device checks remain separate gates.

The 11 frozen case names in generate.py cover configured success, missing/reset deferral, existing/malformed/unreadable pairing, explicit manual-only gates, failures, activation/identity checks, cancellation, skipped device work and strict outcome recognition. The final case checks actual pure wire recognition plus source assertions that the service leaves the existing completion journal incomplete. It does not execute the entire backend terminal path.
