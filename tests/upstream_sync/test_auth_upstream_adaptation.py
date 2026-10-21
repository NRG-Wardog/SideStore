"""Owned fake-value MODEL tests plus Swift SOURCE contracts for the 6.0 port.

No Swift, Security, key generation, keychain, Apple authentication, device APIs,
network or real certificate/key material is executed. Fake key labels model a
proof result; they DO NOT test cryptography or claim iOS/runtime validation.
"""
from dataclasses import dataclass, replace
import os
from pathlib import Path
import unittest

REPO_ROOT = Path(os.environ.get("AUTH_ADAPTATION_REPO_ROOT", str(Path(__file__).resolve().parents[2])))
# Only needed when reviewing a two-file overlay rather than an assembled tree.
SUPPORT_ROOT = Path(os.environ.get("AUTH_ADAPTATION_SUPPORT_ROOT", str(REPO_ROOT)))
PROXY = "SideStore/Core/Auth/DeveloperPortalProxy.swift"
SIGNIN = "SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift"
CERTIFICATE_MANAGER = "SideStore/Core/Certificates/CertificateManager.swift"
KEYCHAIN = "AltStore/Core/Components/Keychain.swift"


class Rejected(Exception):
    pass


@dataclass(frozen=True)
class FakeCertificate:
    serial: str = "owned-fake-serial-a"
    encoded_label: str = "owned-fake-encoding-a"
    public_label: str = "owned-fake-key-a"
    private_label: str = "owned-fake-key-a"
    metadata: str = "minimal"


@dataclass(frozen=True)
class FakePending:
    owner: str
    team: str
    purpose: str
    phase: str
    key_label: str
    encoded_label: str | None = None


class FakeProvisioner:
    """Deterministic contract model. All labels are deliberately non-key values."""
    def __init__(self):
        self.owner = "owned-fake-owner-a"
        self.team = "owned-fake-team-a"
        self.generation = 0
        self.cancelled = False
        self.pending = None
        self.created = FakeCertificate()
        self.portal = [replace(self.created, metadata="full portal metadata")]
        self.create_count = 0
        self.metadata_calls = []
        self.after_create = lambda: None
        self.after_fetch = lambda: None
        self.fetch_error = None
        self.activation_error = False
        self.active = None

    def capture(self):
        return self.owner, self.team, self.generation

    def verify(self, captured):
        if self.cancelled or captured != self.capture():
            raise Rejected("stale or cancelled")

    def fetch_metadata(self, captured):
        self.verify(captured)
        self.metadata_calls.append(captured)
        self.after_fetch()
        if self.fetch_error is not None:
            raise self.fetch_error
        self.verify(captured)
        return self.portal

    def create(self, purpose="provisioning"):
        captured = self.capture()
        self.verify(captured)
        if self.pending is not None:
            raise Rejected("pending creation")
        self.pending = FakePending(self.owner, self.team, purpose, "dispatchMayHaveOccurred", "owned-fake-key-a")
        self.create_count += 1
        result = self.created
        if result.public_label != self.pending.key_label:
            raise Rejected("journal proof")
        self.pending = replace(self.pending, phase="created", encoded_label=result.encoded_label)
        created_record = self.pending
        self.after_create()
        self.verify(captured)
        if purpose != "provisioning":
            return result
        portal = self.fetch_metadata(captured)
        matches = [cert for cert in portal if cert.serial.lower() == result.serial.lower()]
        if len(matches) != 1:
            raise Rejected("ambiguous metadata")
        full = matches[0]
        if full.encoded_label != result.encoded_label or full.public_label != result.private_label:
            raise Rejected("full metadata or returned key proof")
        if self.pending != created_record:
            raise Rejected("journal changed")
        self.verify(captured)
        return replace(full, private_label=result.private_label)

    def activate(self, certificate):
        if self.activation_error:
            raise Rejected("activation failed")
        self.active = certificate
        pending = self.pending
        if pending is None:
            return
        if (self.cancelled or self.owner != pending.owner or self.team != pending.team or
                pending.phase != "created" or self.active.encoded_label != pending.encoded_label or
                self.active.public_label != pending.key_label or self.active.private_label != pending.key_label):
            raise Rejected("persisted copy not verified")
        self.pending = None

    def reconcile(self):
        retained = self.pending
        if retained is None or retained.owner != self.owner or retained.team != self.team:
            raise Rejected("pending owner/team mismatch")
        matches = [cert for cert in self.fetch_metadata(self.capture()) if cert.public_label == retained.key_label]
        if len(matches) != 1 or matches[0].encoded_label != retained.encoded_label:
            raise Rejected("pending proof mismatch")
        return replace(matches[0], private_label=retained.key_label)


def fake_register(primary, fallback, existing, primary_error=None, fallback_error=None):
    """Model the preserved primary/static lookup and changed comparison only."""
    invalid = (None, "", "XXXXX-XXXX-XXXXX-XXXX")
    query_error = primary_error
    identifier = None if primary_error else primary
    if identifier in invalid:
        identifier = None if fallback_error else fallback
        query_error = query_error or fallback_error
    if identifier in invalid:
        raise query_error or Rejected("no verified identifier")
    for candidate in existing:
        if candidate.lower() == identifier.lower():
            return candidate, 0
    return identifier, 1


class DeviceModelTests(unittest.TestCase):
    def test_case_only_difference_reuses_device_without_registration(self):
        self.assertEqual(fake_register("OWNED-FAKE-AbC", None, ["owned-fake-abc"]), ("owned-fake-abc", 0))

    def test_distinct_device_requires_one_registration(self):
        self.assertEqual(fake_register("owned-fake-b", None, ["owned-fake-a"]), ("owned-fake-b", 1))

    def test_static_fallback_remains_available(self):
        self.assertEqual(fake_register("", "OWNED-FAKE-A", ["owned-fake-a"]), ("owned-fake-a", 0))

    def test_missing_empty_and_placeholder_still_rejected(self):
        for invalid in (None, "", "XXXXX-XXXX-XXXXX-XXXX"):
            with self.subTest(invalid=invalid), self.assertRaises(Rejected):
                fake_register(invalid, invalid, [])

    def test_original_typed_query_failure_survives(self):
        original = Rejected("owned-fake-primary-error")
        with self.assertRaises(Rejected) as caught:
            fake_register(None, None, [], original, Rejected("owned-fake-fallback-error"))
        self.assertIs(caught.exception, original)


class CertificateModelTests(unittest.TestCase):
    def test_success_uses_full_metadata_and_preserves_returned_key(self):
        model = FakeProvisioner()
        result = model.create()
        self.assertEqual(result.metadata, "full portal metadata")
        self.assertEqual(result.private_label, model.created.private_label)
        self.assertEqual(model.pending.phase, "created")
        self.assertEqual(model.create_count, 1)
        self.assertEqual(model.metadata_calls, [model.capture()])

    def test_case_only_serial_difference_is_allowed_only_with_same_proof(self):
        model = FakeProvisioner()
        model.portal = [replace(model.portal[0], serial=model.created.serial.upper())]
        self.assertEqual(model.create().metadata, "full portal metadata")

    def test_metadata_timeout_preserves_journal_and_cannot_replay_create(self):
        model = FakeProvisioner()
        original = TimeoutError("owned-fake-read-timeout")
        model.fetch_error = original
        with self.assertRaises(TimeoutError) as caught:
            model.create()
        self.assertIs(caught.exception, original)
        self.assertEqual(model.pending.phase, "created")
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.create_count, 1)

    def test_owner_switch_after_create_blocks_metadata_request(self):
        model = FakeProvisioner()
        model.after_create = lambda: setattr(model, "owner", "owned-fake-owner-b")
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.metadata_calls, [])
        self.assertEqual(model.pending.owner, "owned-fake-owner-a")
        self.assertEqual(model.pending.phase, "created")

    def test_owner_switch_during_fetch_cannot_return_cross_owner_certificate(self):
        model = FakeProvisioner()
        model.after_fetch = lambda: setattr(model, "owner", "owned-fake-owner-b")
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.pending.owner, "owned-fake-owner-a")
        self.assertIsNone(model.active)

    def test_same_owner_new_identity_generation_rejected(self):
        model = FakeProvisioner()
        model.after_fetch = lambda: setattr(model, "generation", 1)
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.pending.phase, "created")

    def test_team_drift_blocks_metadata_read(self):
        model = FakeProvisioner()
        model.after_create = lambda: setattr(model, "team", "owned-fake-team-b")
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.metadata_calls, [])
        self.assertEqual(model.pending.team, "owned-fake-team-a")

    def test_cancellation_after_mutation_preserves_created_journal(self):
        model = FakeProvisioner()
        model.after_create = lambda: setattr(model, "cancelled", True)
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.pending.phase, "created")
        self.assertEqual(model.metadata_calls, [])

    def test_cancellation_during_metadata_fetch_preserves_journal(self):
        model = FakeProvisioner()
        model.after_fetch = lambda: setattr(model, "cancelled", True)
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.pending.phase, "created")

    def test_same_serial_different_encoded_certificate_rejected(self):
        model = FakeProvisioner()
        model.portal = [replace(model.portal[0], encoded_label="owned-fake-other-encoding")]
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.pending.encoded_label, model.created.encoded_label)

    def test_returned_private_key_mismatch_rejected(self):
        model = FakeProvisioner()
        model.created = replace(model.created, private_label="owned-fake-wrong-key")
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.pending.phase, "created")

    def test_unproven_create_result_preserves_dispatched_journal(self):
        model = FakeProvisioner()
        model.created = replace(model.created, public_label="owned-fake-wrong-public-key")
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.pending.phase, "dispatchMayHaveOccurred")

    def test_absent_metadata_is_incomplete_not_create_retry(self):
        model = FakeProvisioner()
        model.portal = []
        with self.assertRaises(Rejected):
            model.create()
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.create_count, 1)
        self.assertIsNotNone(model.pending)

    def test_duplicate_metadata_identity_is_rejected(self):
        model = FakeProvisioner()
        model.portal *= 2
        with self.assertRaises(Rejected):
            model.create()
        self.assertEqual(model.pending.phase, "created")

    def test_changed_journal_is_not_silently_accepted(self):
        model = FakeProvisioner()
        model.after_fetch = lambda: setattr(model, "pending", replace(model.pending, team="owned-fake-other-team"))
        with self.assertRaises(Rejected):
            model.create()
        self.assertIsNotNone(model.pending)

    def test_activation_failure_keeps_journal_and_original_result_for_retry(self):
        model = FakeProvisioner()
        result = model.create()
        model.activation_error = True
        with self.assertRaises(Rejected):
            model.activate(result)
        self.assertEqual(model.pending.phase, "created")
        model.activation_error = False
        model.activate(result)
        self.assertIsNone(model.pending)
        self.assertEqual(model.create_count, 1)
        self.assertEqual(len(model.metadata_calls), 1)

    def test_only_verified_activation_clears_journal(self):
        model = FakeProvisioner()
        result = model.create()
        with self.assertRaises(Rejected):
            model.activate(replace(result, private_label="owned-fake-wrong-key"))
        self.assertIsNotNone(model.pending)
        model.activate(result)
        self.assertIsNone(model.pending)

    def test_restart_reconciles_created_record_without_new_server_mutation(self):
        initial = FakeProvisioner()
        initial.fetch_error = TimeoutError("owned-fake-read-timeout")
        with self.assertRaises(TimeoutError):
            initial.create()
        restarted = FakeProvisioner()
        restarted.pending = initial.pending
        recovered = restarted.reconcile()
        self.assertIsNotNone(restarted.pending)
        restarted.activate(recovered)
        self.assertIsNone(restarted.pending)
        self.assertEqual(initial.create_count + restarted.create_count, 1)

    def test_other_owner_cannot_reconcile_retained_certificate(self):
        model = FakeProvisioner()
        model.create()
        model.owner = "owned-fake-owner-b"
        with self.assertRaises(Rejected):
            model.reconcile()
        self.assertIsNotNone(model.pending)

    def test_imported_copy_keeps_existing_no_metadata_behavior(self):
        model = FakeProvisioner()
        model.fetch_error = TimeoutError("must not fetch")
        self.assertEqual(model.create(purpose="importedCopy"), model.created)
        self.assertEqual(model.metadata_calls, [])
        self.assertEqual(model.pending.purpose, "importedCopy")


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class SwiftSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proxy = (REPO_ROOT / PROXY).read_text()
        cls.signin = (REPO_ROOT / SIGNIN).read_text()
        cls.create = section(cls.proxy, "public func createCertificate(", "public func revokeCertificate(")
        cls.enrichment = (section(cls.create, "// V3_JOURNALED_CERTIFICATE_METADATA_ENRICHMENT_V1", "\n    }")
                          if "// V3_JOURNALED_CERTIFICATE_METADATA_ENRICHMENT_V1" in cls.create else "")
        cls.device = section(cls.signin, "private func registerCurrentDevice(", "// LOGIN_STAGE_OBSERVER_V1")

    def test_case_insensitive_lookup_precedes_only_registration_call(self):
        comparison = "$0.identifier.caseInsensitiveCompare(udid) == .orderedSame"
        self.assertIn(comparison, self.device)
        self.assertEqual(self.device.count("DeveloperPortalProxy.shared.registerDevice("), 1)
        self.assertLess(self.device.index(comparison), self.device.index("registerDevice(name:"))
        self.assertIn("return device\n        } else {", self.device)

    def test_original_verified_udid_and_typed_failure_guards_remain(self):
        for text in ("deviceUDID = try await fetchUDID()", "fetchUDID(useStatic: true)",
                     'guard let udid = deviceUDID, !udid.isEmpty, udid != "XXXXX-XXXX-XXXXX-XXXX"',
                     "if let deviceQueryError { throw deviceQueryError }"):
            self.assertIn(text, self.device)

    def test_journal_proof_and_created_record_precede_metadata_fetch(self):
        order = ["V3CertificateMutationAdmission.acquire()", "getBoundSession()", "getBoundTeam(team, context: context)",
                 "pendingCertificateCreation() == nil", "beginPendingCertificateCreation(",
                 "advancePendingCertificateCreation(prepared)", "ALTAppleAPI.shared.addCertificate(",
                 "privateKeyPEM: dispatched.privateKey", "let created = try Keychain.shared.advancePendingCertificateCreation(dispatched, certificateDER: der)",
                 "guard purpose == .provisioning", "ALTAppleAPI.shared.fetchCertificates("]
        for text in order:
            self.assertIn(text, self.create)
        positions = [self.create.index(text) for text in order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("defer { V3CertificateMutationAdmission.release(token) }", self.create)

    def test_original_identity_team_and_session_own_metadata_read(self):
        self.assertIn("let metadataTeam = try await getBoundTeam(team, context: context)", self.enrichment)
        self.assertIn("metadataTeam.identifier == created.teamID", self.enrichment)
        self.assertIn("context.session.dsid == created.ownerDSID", self.enrichment)
        self.assertIn("try await awaitBound(context)", self.enrichment)
        self.assertIn("fetchCertificates(for: metadataTeam, session: context.session)", self.enrichment)
        self.assertNotIn("getBoundSession()", self.enrichment)
        self.assertNotIn("DeveloperPortalProxy.shared.fetchCertificates", self.enrichment)

    def test_await_bound_checks_identity_before_and_after_read(self):
        body = section(self.proxy, "private func awaitBound<T>(", "private struct DatabaseTeamOwnershipSnapshot")
        self.assertEqual(body.count("try verifyCurrent(context)"), 2)
        self.assertLess(body.index("try verifyCurrent(context)"), body.index("let value = try await operation()"))
        self.assertGreater(body.rindex("try verifyCurrent(context)"), body.index("let value = try await operation()"))
        verification = section(self.proxy, "private func verifyCurrent(", "private func awaitBound<T>(")
        for text in ("capturedStamp: context.identityStamp", "context.generation == auth.v3IdentityGeneration", "cancelled: Task.isCancelled", "hasUsableSession(", "mayUseTeam("):
            self.assertIn(text, verification)

    def test_unique_serial_match_requires_exact_der_and_existing_key_proof(self):
        for text in ("$0.serialNumber.caseInsensitiveCompare(certificate.serialNumber) == .orderedSame",
                     "guard matches.count == 1", "fullX509.data == der",
                     "V3PendingCertificateKeyProof.matches(certificateDER: der, privateKeyPEM: certificate.privateKey)"):
            self.assertIn(text, self.enrichment)
        self.assertLess(self.enrichment.index("fullX509.data == der"), self.enrichment.index("return ALTCertificate("))

    def test_returned_private_key_is_not_replaced(self):
        self.assertIn("return ALTCertificate(x509: fullX509, privateKey: certificate.privateKey)", self.enrichment)
        self.assertNotIn("privateKey: created.privateKey", self.enrichment)
        self.assertNotIn("privateKey: fullX509", self.enrichment)

    def test_no_metadata_failure_fallback_retry_or_journal_deletion(self):
        self.assertEqual(self.create.count("ALTAppleAPI.shared.addCertificate("), 1)
        for forbidden in ("catch", "try?", "clearPrepared", "completePending", "saveCertificate(", "setActiveCertificate(", "beginPending", "addCertificate(", "while "):
            self.assertNotIn(forbidden.lower(), self.enrichment.lower())
        self.assertIn("guard try Keychain.shared.pendingCertificateCreation() == created", self.enrichment)
        self.assertIn("try verifyCurrent(context)\n        return ALTCertificate", self.enrichment)

    def test_original_provisioning_purpose_and_pending_recovery_remain(self):
        self.assertIn("createCertificate(machineName: machineName, team: team, purpose: .provisioning)", self.signin)
        fetch = section(self.signin, "private func fetchCertificate(", "private func requestCertificate(")
        self.assertIn("if let pending = try Keychain.shared.pendingCertificateCreation()", fetch)
        self.assertIn("self.v3FinishPendingCertificateActivation, pending.purpose == .provisioning", fetch)
        self.assertIn("reconcilePendingCertificateCreation(team: team)", fetch)
        self.assertLess(fetch.index("pendingCertificateCreation()"), fetch.index("fetchCertificates(team: team)"))

    def test_activation_retry_retains_result_and_completion_order(self):
        body = section(self.signin, "// Retain the obtained certificate across local save retries.", "// 3. Register Current Device")
        self.assertIn("if resolvedCertificate == nil", body)
        self.assertLess(body.index("setActiveCertificate(certificate)"), body.index("v3CompletePendingCertificateIfStored(certificate)"))
        self.assertIn("guard isCertificateResolved else { continue }", body)

    def test_readiness_and_host_owned_account_state_are_unchanged(self):
        self.assertIn("self.v3DidCompleteProvisioning = !self.skipDeviceRegistration &&", self.signin)
        self.assertIn("!self.skipCertificateProvisioning && resolvedCertificate != nil", self.signin)
        self.assertIn("A partial provision must not publish successful headless readiness.", self.signin)
        self.assertIn("V3_AUTH_FAILURE_PRESERVES_ACCOUNT_STATE_V1", self.signin)

    def test_reconciliation_checks_owner_team_der_and_does_not_create(self):
        body = section(self.proxy, "public func reconcilePendingCertificateCreation(", "public func fetchDevices(")
        for text in ("context.session.dsid == retained.ownerDSID", "team.identifier == retained.teamID",
                     "privateKeyPEM: retained.privateKey", "retained.certificateDER != der",
                     "retained.purpose == .importedCopy"):
            self.assertIn(text, body)
        self.assertNotIn("addCertificate(", body)

    def test_journal_clears_only_after_stored_copy_verification(self):
        source = (SUPPORT_ROOT / CERTIFICATE_MANAGER).read_text()
        body = section(source, "public func v3CompletePendingCertificateIfStored(", "public func clearActiveCertificate(")
        for text in ("record.phase == .created", "certificate.x509.data == der", "storedCopyIsVerified:",
                     "let stored = try Self.parse(bytes, password: password)", "stored.x509.data == der",
                     "privateKeyDER: stored.privateKey", "auth.v3IdentityGeneration == generation"):
            self.assertIn(text, body)
        storage = (SUPPORT_ROOT / KEYCHAIN).read_text()
        body = section(storage, "static func completePendingCertificateCreation(", "private static let certificateMarker")
        for text in ("record.ownerDSID", "record.purpose == .provisioning", 'getData("signingCertificate")',
                     "storedCopyIsVerified(data, password)"):
            self.assertIn(text, body)

    def test_new_enrichment_adds_no_private_diagnostics_or_authentication(self):
        for forbidden in ("debugLog(", "print(", "authenticate(", "signOut(", "writeAuthentication", "http", "SecKeyCreate"):
            self.assertNotIn(forbidden.lower(), self.enrichment.lower())


if __name__ == "__main__":
    unittest.main()
