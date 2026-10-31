# Actual-source producer/consumer regression

`run.sh` additionally compiles/runs `generate_producer_consumer.py` output with Swift 6 and production AppBundleFingerprint.swift (including CryptoKit). The generator extracts actual `acknowledgedReuseMainIdentity`, actual post-ACK recording statements, and actual PipelineRunner historical-evidence consumer block; no handwritten AcknowledgedIdentity is constructed in the cases.

Seven exact JSON case identities are required. Original/staged Info.plists are real disk files, original source contains no signed-generation marker, and both source fingerprint algorithms are production. Missing signed generation, certificate/profile mismatch, and modified source exercise actual producer/consumer rejection. SDK application/profile/certificate models and CoreData queue are inert doubles.

The failed-ACK case models a failing native dispatch boundary and does not call the actual post-ACK recording block. Generator also checks that extracted recording follows native install calls and ACK in actual production source. This is NOT full InstallAppOperation/native-install execution; existing install-boundary suites and full app compilation remain mandatory. No device or portal operations occur.

Local status: extraction and shell syntax checked; native execution pending (swiftc unavailable).
