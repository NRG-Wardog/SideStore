"""Read maintained owner source directly; never invoke the retired authorship path.

Portable tests establish exact source identity and structural contracts, not Swift
execution. The Swift tests execute extracted real declarations when swiftc exists.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("verify_runtime_source", ROOT / "scripts/verify_runtime_source.py")
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
SWIFTC = shutil.which("swiftc")


def section(source, first, following):
    start = source.index(first)
    return source[start:source.index(following, start)]


class SourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ROOT / "docs/runtime-migration/source-manifest.json").read_text())
        cls.mapping = json.loads((ROOT / "docs/runtime-migration/subsystem-mapping.json").read_text())
        cls.app = (ROOT / "AltStore/AppDelegate.swift").read_text()
        cls.keychain = (ROOT / "AltStore/Core/Components/Keychain.swift").read_text()

    def source(self, relative):
        return (ROOT / relative).read_text()

    def test_whole_owner_tree_exact_hashes_modes_and_inventory(self):
        self.assertEqual(VERIFY.verify_files(ROOT, self.manifest), 628)
        self.assertEqual(len(self.manifest["changed_paths"]), 48)

    def test_exact_ancestry_gitlinks_clean_tree_and_tracked_inventory(self):
        VERIFY.verify_git(ROOT, self.manifest, require_clean=True)

    def test_original_licenses_and_attribution(self):
        for path in ("LICENSE", "CERTIFICATE-OF-ORIGIN.md"):
            entry = self.manifest["files"][path]
            self.assertEqual(entry["sha256"], entry["upstream_sha256"])
        actual = VERIFY.digest((ROOT / "LICENSES/sidestore-auto-refresh-MIT.txt").read_bytes())
        self.assertEqual(actual, self.mapping["exact_original_mit_notice_sha256"])

    def test_every_product_change_has_stage_and_commit_mapping(self):
        rows = {r["file"].removeprefix("SideStore:"): r for r in self.mapping["changed_files"]}
        for path in self.manifest["changed_paths"]:
            self.assertTrue(rows[path]["pipelines"], path)
            self.assertEqual(rows[path]["after"]["sha256"], self.manifest["files"][path]["sha256"])
        self.assertEqual([c["order"] for c in self.mapping["source_commits"]["commits"]], list(range(1, 9)))

    def test_app_delegate_review_slices_preserve_every_final_byte(self):
        lines = (ROOT / "AltStore/AppDelegate.swift").read_bytes().splitlines(keepends=True)
        ranges = sorted((s for c in self.mapping["source_commits"]["commits"]
                         for s in c["app_delegate_segments"]), key=lambda s: s["start_line"])
        next_line = 376
        for s in ranges:
            self.assertEqual(s["start_line"], next_line)
            self.assertEqual(VERIFY.digest(b"".join(lines[s["start_line"]-1:s["end_line"]])), s["sha256"])
            next_line = s["end_line"] + 1
        self.assertEqual(next_line, len(lines) + 1)

    def test_preparation_sidecar_is_not_a_product_prerequisite(self):
        self.assertFalse((ROOT / ".combined-refresh-contract.json").exists())
        self.assertNotIn(".combined-refresh-contract.json", self.manifest["files"])
        self.assertIn(".combined-refresh-contract.json", self.manifest["excluded_preparation_evidence"])

    def test_pinned_package_resolution_and_valid_plist(self):
        lock = json.loads(self.source("AltStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        pins = {p["identity"]: p for p in lock["pins"]}
        self.assertEqual(pins["anisettekit"]["state"]["revision"], "1f5a7e36553cc865b873f222b87a6486c0bcc7bf")
        for pin in pins.values():
            self.assertRegex(pin["state"]["revision"], r"^[0-9a-f]{40}$")
        plistlib.loads((ROOT / "AltStore/Info.plist").read_bytes())

    def test_signin_transactions_precede_session_publication(self):
        signin = self.source("SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift")
        signin = section(signin, "private func signIn(appleID:", "private func finalizeAuthentication")
        self.assertLess(signin.index("v3ValidateReauthenticationIdentity"), signin.index("AuthManager.shared.signIn"))
        self.assertLess(signin.index("writeAuthenticationCredentials"), signin.index("AuthManager.shared.session = session"))
        self.assertIn("defer { AuthManager.shared.v3CompleteIdentityTransition() }", signin)

    def test_auth_identity_is_rechecked_across_network_suspend(self):
        auth = self.source("SideStore/Core/Auth/AuthManager.swift")
        self.assertIn("V3AuthSessionCoalescerKey.value(for: identityAtStart.stamp)", auth)
        self.assertLess(auth.index("let anisetteData = try await AnisetteProvider.fetch()"),
                        auth.index("let credentialSnapshotAfter:"))
        self.assertIn("guard self.v3InstallSessionIfCurrent(session, capturedStamp: identityAtStart.stamp)", auth)

    def test_two_factor_phone_dispatch_and_code_retry_are_retained(self):
        phone = section(self.app, "enum V3TwoFactorPhoneSelectionPolicy", "@MainActor\nfinal class V3HeadlessAuthHandler")
        self.assertIn('phoneIDs.contains(phoneID)', phone)
        self.assertIn('case "sms": return .requestSMS(phoneID: phoneID)', phone)
        self.assertIn('case "voice": return .requestVoice(phoneID: phoneID)', phone)
        retry = section(self.app, "enum V3TwoFactorRetryPolicy", "struct V3AuthStartCancellationRegistry")
        self.assertIn('authFailureKind == "invalidCode"', retry)

    def test_keychain_pair_validation_precedes_identity_creation(self):
        resolve = section(self.keychain, "static func resolveAnisetteSnapshot(_ client:", "static func commitAnisetteBlob")
        self.assertLess(resolve.index(".validated()"), resolve.index('writeOne("identifier"'))
        self.assertIn("withSharedTransaction", resolve)
        commit = section(self.keychain, "static func commitAnisetteBlob", "private static func legacyAnisetteItems")
        self.assertIn("guard current == snapshot.stored", commit)
        self.assertIn("guard blob == existing", commit)

    def test_normal_anisette_keeps_provider_and_pair_snapshot(self):
        provider = self.source("SideStore/Core/Anisette/OnDeviceAnisetteManager.swift")
        normal = section(provider, "public func fetchAnisetteData()", "private enum LCAnisetteIsolatedProbe")
        self.assertIn("AnisetteMode.remoteODA(sourceURL: sourceURL, fallbackURL: fallbackURL)", normal)
        self.assertIn("existingAdiBlob: existingAdiPbData", normal)
        self.assertIn("commitAnisetteBlob(freshBlob, snapshot: anisetteSnapshot)", normal)

    def test_automatic_recovery_stays_disabled_in_policy_and_caller(self):
        self.assertIn("static let automaticRecoveryEnabled = false", self.keychain)
        provider = self.source("SideStore/Core/Anisette/OnDeviceAnisetteManager.swift")
        recovery = section(provider, "private func recoverVerifiedLegacyIdentity", "let libraries = provider.libsDir")
        self.assertIn("guard LCAnisetteRecoveryPolicy.automaticRecoveryEnabled else", recovery)
        self.assertIn("throw diagnosed(.automaticRecoveryDisabled)", recovery)
        commit = self.keychain[self.keychain.index("static func commitAnisetteRecovery"):]
        self.assertLess(commit.index("guard LCAnisetteRecoveryPolicy.automaticRecoveryEnabled"), commit.index("withSharedTransaction"))

    def test_finite_trace_is_enabled_in_release_baseline(self):
        trace = section(self.app, "public struct V3TemporaryAnisetteTrace", "struct V3AnisetteAttemptContext")
        self.assertIn("temporaryAnisetteTraceEnabled = true", trace)
        self.assertIn("maximumEvents = 64", trace)
        self.assertIn("maximumBytes = 2048", trace)
        self.assertNotIn("#if DEBUG", trace)
        self.assertIn("guard let event = NativeEvent(rawValue: token)", trace)

    def test_shared_group_contract_and_fail_closed_storage(self):
        self.assertIn('runtimeGroupEnvironmentKey = "LC_V3_INHERITED_APP_GROUP"', self.app)
        background = self.source("SideStore/Core/Operations/StandaloneOperations/BackgroundRefreshAppsOperation.swift")
        shared = section(background, "private func automaticRefreshDefaults", "private func persistAutomaticHostHandoff")
        self.assertIn("try V3SharedAppGroup.requireSharedUserDefaults()", shared)
        self.assertNotIn("return .standard", shared)

    def test_certificate_memory_publication_follows_durable_write(self):
        cert = self.source("SideStore/Core/Certificates/CertificateManager.swift")
        active = section(cert, "public func setActiveCertificate", "public func clearActiveCertificate")
        self.assertLess(active.index("try Keychain.shared.writeSigningCertificate"),
                        active.index("self.activeCertificate = ActiveSigningCertificate"))
        self.assertIn('native.code == 1010', active)
        self.assertIn("guard parsed.serialNumber == cert.serialNumber", active)

    def test_transport_lease_and_underlying_send_error_are_retained(self):
        runner = self.source("SideStore/Core/Operations/PipelineRunner.swift")
        self.assertLess(runner.index("await transportCore.beginTransportBatch()"), runner.index("if !CellularRefreshManager.shared.isEnabled"))
        self.assertEqual(runner.count("await transportCore.endTransportBatch()"), 2)
        self.assertIn("V3MutationPersistencePolicy.persistResult", runner)
        send = self.source("SideStore/Core/Operations/PipelineOperations/SendAppOperation.swift")
        self.assertIn("// Preserve the underlying AFC failure instead of reporting a missing app.\n            throw error", send)

    def test_host_replacement_stays_after_normal_operations(self):
        runner = self.source("SideStore/Core/Operations/PipelineRunner.swift")
        self.assertLess(runner.index("for operation in normalOperations"), runner.index("for operation in hostOperations"))
        self.assertIn("try Task.checkCancellation()", runner[runner.index("for operation in hostOperations"):])

    def test_headless_gate_and_explicit_prompt_runtime_are_retained(self):
        self.assertIn("final class V3SideStoreService: NSObject", self.app)
        self.assertIn("final class V3PromptCenter: @unchecked Sendable", self.app)
        self.assertIn("static let requestLimit = 16_384", self.app)
        self.assertIn("static let responseLimit = 4_194_304", self.app)
        for token in ("V3_HEADLESS_AUTH_ENTRYPOINT_V1",):
            self.assertIn(token, self.source("SideStore/Core/Auth/AuthManager.swift"))


class VerifierMutationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Source.swift").write_text("let value = 1\n")
        self.manifest = {"files": {"Source.swift": VERIFY.describe(self.root / "Source.swift")},
                         "gitlinks": {}, "allowed_nonruntime_files": []}

    def test_verification_is_read_only_and_repeatable(self):
        before = (self.root / "Source.swift").read_bytes()
        for _ in range(2):
            self.assertEqual(VERIFY.verify_files(self.root, self.manifest), 1)
        self.assertEqual((self.root / "Source.swift").read_bytes(), before)

    def test_extra_source_is_rejected(self):
        (self.root / "Extra.swift").write_text("let other = 2\n")
        with self.assertRaisesRegex(VERIFY.ParityError, "Inventory drift"):
            VERIFY.verify_files(self.root, self.manifest)

    def test_missing_source_is_rejected(self):
        (self.root / "Source.swift").unlink()
        with self.assertRaisesRegex(VERIFY.ParityError, "Inventory drift"):
            VERIFY.verify_files(self.root, self.manifest)

    def test_marker_preserving_byte_drift_is_rejected(self):
        (self.root / "Source.swift").write_text("let value = 2\n")
        with self.assertRaisesRegex(VERIFY.ParityError, "Byte/mode drift"):
            VERIFY.verify_files(self.root, self.manifest)

    def test_executable_mode_drift_is_rejected(self):
        (self.root / "Source.swift").chmod(0o755)
        with self.assertRaisesRegex(VERIFY.ParityError, "Byte/mode drift"):
            VERIFY.verify_files(self.root, self.manifest)

    def test_symlink_substitution_is_rejected(self):
        path = self.root / "Source.swift"
        path.unlink()
        path.symlink_to("missing-target")
        with self.assertRaisesRegex(VERIFY.ParityError, "Byte/mode drift"):
            VERIFY.verify_files(self.root, self.manifest)

    def test_unexpected_directory_symlink_is_rejected(self):
        (self.root / "Unexpected").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(VERIFY.ParityError, "Inventory drift"):
            VERIFY.verify_files(self.root, self.manifest)

    def test_old_sidecar_is_explicitly_allowed_but_hash_checked(self):
        p = self.root / ".patch-state.json"
        p.write_text('{"frozen":true}\n')
        self.manifest["excluded_preparation_evidence"] = {p.name: VERIFY.describe(p)}
        VERIFY.verify_files(self.root, self.manifest, old_pipeline=True)
        with self.assertRaisesRegex(VERIFY.ParityError, "Inventory drift"):
            VERIFY.verify_files(self.root, self.manifest)
        p.write_text('{}\n')
        with self.assertRaisesRegex(VERIFY.ParityError, "Preparation evidence drift"):
            VERIFY.verify_files(self.root, self.manifest, old_pipeline=True)


class GitProofAdversarialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.good = self.directory / "good"
        self.good.mkdir()
        self.fixture_environment = {key: value for key, value in os.environ.items()
                                    if not key.startswith("GIT_")}
        self.fixture_environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": os.devnull,
                                         "GIT_CONFIG_GLOBAL": os.devnull})
        self.raw_git(self.good, "init", "--quiet")
        (self.good / "Source.swift").write_text("let value = 1\n")
        self.raw_git(self.good, "add", "Source.swift")
        self.raw_git(self.good, "commit", "--quiet", "-m", "upstream fixture")
        self.base = self.raw_git(self.good, "rev-parse", "HEAD").decode().strip()
        self.manifest = {"files": {"Source.swift": VERIFY.describe(self.good / "Source.swift")},
                         "gitlinks": {}, "allowed_nonruntime_files": [],
                         "upstream_base": self.base,
                         "upstream_tree": self.raw_git(self.good, "rev-parse", "HEAD^{tree}").decode().strip()}
        self.raw_git(self.good, "commit", "--quiet", "--allow-empty", "-m", "valid descendant")
        self.good_head = self.raw_git(self.good, "rev-parse", "HEAD").decode().strip()
        self.bad = self.directory / "bad"
        subprocess.run(["git", "clone", "--quiet", "--shared", str(self.good), str(self.bad)],
                       check=True, env=self.fixture_environment, capture_output=True)

    def raw_git(self, root, *arguments, input_data=None):
        return subprocess.check_output(["git", "-C", str(root), "-c", "user.name=Migration gate fixture",
                                        "-c", "user.email=fixture@example.invalid", *arguments],
                                       input=input_data, env=self.fixture_environment, stderr=subprocess.STDOUT)

    def make_orphan(self, root=None):
        root = root or self.bad
        tree = self.raw_git(root, "rev-parse", "HEAD^{tree}").decode().strip()
        orphan = self.raw_git(root, "commit-tree", tree, input_data=b"orphan proof fixture\n").decode().strip()
        self.raw_git(root, "reset", "--quiet", "--hard", orphan)
        return orphan

    def test_orphan_head_cannot_borrow_redirected_valid_git_directory(self):
        self.make_orphan()
        VERIFY.verify_files(self.bad, self.manifest)
        with patch.dict(os.environ, {"GIT_DIR": str(self.good / ".git"), "GIT_WORK_TREE": str(self.good)}):
            with self.assertRaises(subprocess.CalledProcessError):
                VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_exact_full_owner_cli_orphan_redirection_regression(self):
        clone = self.directory / "full-owner"
        subprocess.run(["git", "clone", "--quiet", "--shared", str(ROOT), str(clone)],
                       check=True, env=self.fixture_environment, capture_output=True)
        self.make_orphan(clone)
        environment = dict(self.fixture_environment, GIT_DIR=str(ROOT / ".git"), GIT_WORK_TREE=str(ROOT))
        result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/verify_runtime_source.py"),
                                 "--root", str(clone), "--require-clean"], capture_output=True,
                                text=True, env=environment, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SIDESTORE_RUNTIME_SOURCE_PARITY_PASS", result.stdout)
        self.assertIn("merge-base", result.stderr)

    def test_exact_full_owner_cli_rejects_hidden_committed_runtime(self):
        clone = self.directory / "full-owner-committed-drift"
        subprocess.run(["git", "clone", "--quiet", "--shared", str(ROOT), str(clone)],
                       check=True, env=self.fixture_environment, capture_output=True)
        path = clone / "AltStore/AppDelegate.swift"
        original = path.read_bytes()
        path.write_bytes(original + b"\nlet unexpectedCommittedRuntime = 123\n")
        self.raw_git(clone, "add", "AltStore/AppDelegate.swift")
        self.raw_git(clone, "commit", "--quiet", "-m", "unexpected committed runtime")
        path.write_bytes(original)
        self.raw_git(clone, "update-index", "--assume-unchanged", "AltStore/AppDelegate.swift")
        self.assertEqual(self.raw_git(clone, "status", "--porcelain").strip(), b"")
        result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/verify_runtime_source.py"),
                                 "--root", str(clone), "--require-clean"], capture_output=True,
                                text=True, env=self.fixture_environment, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SIDESTORE_RUNTIME_SOURCE_PARITY_PASS", result.stdout)
        self.assertIn("Committed byte/mode drift: AltStore/AppDelegate.swift", result.stderr)

    def test_environment_discards_every_inherited_git_override(self):
        overrides = {"GIT_DIR": "untrusted", "GIT_COMMON_DIR": "untrusted",
                     "GIT_INDEX_FILE": "untrusted", "GIT_OBJECT_DIRECTORY": "untrusted",
                     "GIT_ALTERNATE_OBJECT_DIRECTORIES": "untrusted", "GIT_NAMESPACE": "untrusted",
                     "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.worktree",
                     "GIT_CONFIG_VALUE_0": "untrusted", "GIT_REPLACE_REF_BASE": "untrusted",
                     "GIT_CONFIG_SYSTEM": "untrusted", "GIT_CONFIG_GLOBAL": "untrusted"}
        with patch.dict(os.environ, overrides):
            environment = VERIFY.proof_environment()
        for key in overrides:
            if key in ("GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL"):
                self.assertEqual(environment[key], os.devnull)
            else:
                self.assertNotIn(key, environment)
        self.assertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(environment["GIT_GRAFT_FILE"], os.devnull)
        self.assertEqual(environment["GIT_NO_REPLACE_OBJECTS"], "1")

    def test_shallow_boundary_cannot_masquerade_as_complete_history(self):
        (self.bad / ".git/shallow").write_text(self.base + "\n")
        self.assertEqual(self.raw_git(self.bad, "rev-parse", "--is-shallow-repository").decode().strip(), "true")
        self.raw_git(self.bad, "merge-base", "--is-ancestor", self.base, "HEAD")
        with self.assertRaisesRegex(VERIFY.ParityError, "Shallow history"):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_committed_proof_metadata_symlink_is_rejected(self):
        (self.bad / "proof.json").symlink_to("Source.swift")
        self.raw_git(self.bad, "add", "proof.json")
        self.raw_git(self.bad, "commit", "--quiet", "-m", "symlink proof metadata")
        self.manifest["allowed_nonruntime_files"] = ["proof.json"]
        self.assertEqual(self.raw_git(self.bad, "status", "--porcelain").strip(), b"")
        with self.assertRaisesRegex(VERIFY.ParityError, "regular 100644"):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_committed_executable_proof_metadata_is_rejected(self):
        metadata = self.bad / "proof.json"
        metadata.write_text("{}\n")
        metadata.chmod(0o755)
        self.raw_git(self.bad, "add", "proof.json")
        self.raw_git(self.bad, "commit", "--quiet", "-m", "executable proof metadata")
        self.manifest["allowed_nonruntime_files"] = ["proof.json"]
        with self.assertRaisesRegex(VERIFY.ParityError, "regular 100644"):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_replace_ref_cannot_fabricate_upstream_ancestry(self):
        orphan = self.make_orphan()
        self.raw_git(self.bad, "replace", orphan, self.good_head)
        # Establish the attack changes ordinary Git's ancestry result.
        self.raw_git(self.bad, "merge-base", "--is-ancestor", self.base, "HEAD")
        with self.assertRaises(subprocess.CalledProcessError):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_graft_file_cannot_fabricate_upstream_ancestry(self):
        orphan = self.make_orphan()
        (self.bad / ".git/info/grafts").write_text(orphan + " " + self.base + "\n")
        self.raw_git(self.bad, "merge-base", "--is-ancestor", self.base, "HEAD")
        with self.assertRaises(subprocess.CalledProcessError):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_inherited_graft_override_cannot_fabricate_upstream_ancestry(self):
        orphan = self.make_orphan()
        graft = self.directory / "external-grafts"
        graft.write_text(orphan + " " + self.base + "\n")
        with patch.dict(os.environ, {"GIT_GRAFT_FILE": str(graft)}):
            with self.assertRaises(subprocess.CalledProcessError):
                VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_global_worktree_override_cannot_redirect_dirty_check(self):
        config = self.directory / "global-config"
        config.write_text("[core]\n\tworktree = " + str(self.good) + "\n")
        with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": str(config),
                                     "GIT_WORK_TREE": str(self.good), "GIT_INDEX_FILE": str(self.good / ".git/index")}):
            self.assertEqual(VERIFY.git(self.bad, "rev-parse", "--show-toplevel").decode().strip(), str(self.bad))
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_runtime_head_blob_is_checked_despite_assume_unchanged(self):
        path = self.bad / "Source.swift"
        original = path.read_bytes()
        path.write_bytes(original + b"let unexpectedCommittedRuntime = 123\n")
        self.raw_git(self.bad, "add", "Source.swift")
        self.raw_git(self.bad, "commit", "--quiet", "-m", "unexpected committed runtime")
        path.write_bytes(original)
        self.raw_git(self.bad, "update-index", "--assume-unchanged", "Source.swift")
        self.assertEqual(self.raw_git(self.bad, "status", "--porcelain").strip(), b"")
        VERIFY.verify_files(self.bad, self.manifest)
        with self.assertRaisesRegex(VERIFY.ParityError, "Committed byte/mode drift"):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_runtime_head_mode_is_checked_despite_assume_unchanged(self):
        path = self.bad / "Source.swift"
        path.chmod(0o755)
        self.raw_git(self.bad, "add", "Source.swift")
        self.raw_git(self.bad, "commit", "--quiet", "-m", "unexpected executable mode")
        path.chmod(0o644)
        self.raw_git(self.bad, "update-index", "--assume-unchanged", "Source.swift")
        VERIFY.verify_files(self.bad, self.manifest)
        with self.assertRaisesRegex(VERIFY.ParityError, "Committed byte/mode drift"):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_replacement_blob_cannot_mask_committed_runtime_drift(self):
        path = self.bad / "Source.swift"
        original = path.read_bytes()
        expected_oid = self.raw_git(self.bad, "rev-parse", "HEAD:Source.swift").decode().strip()
        path.write_bytes(original + b"let unexpectedCommittedRuntime = 123\n")
        self.raw_git(self.bad, "add", "Source.swift")
        self.raw_git(self.bad, "commit", "--quiet", "-m", "unexpected committed runtime")
        wrong_oid = self.raw_git(self.bad, "rev-parse", "HEAD:Source.swift").decode().strip()
        self.raw_git(self.bad, "replace", wrong_oid, expected_oid)
        self.assertEqual(self.raw_git(self.bad, "cat-file", "blob", wrong_oid), original)
        path.write_bytes(original)
        self.raw_git(self.bad, "update-index", "--assume-unchanged", "Source.swift")
        with self.assertRaisesRegex(VERIFY.ParityError, "Committed byte/mode drift"):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_index_override_cannot_hide_a_different_staged_blob(self):
        oid = self.raw_git(self.bad, "hash-object", "-w", "--stdin", input_data=b"wrong staged source\n").decode().strip()
        self.raw_git(self.bad, "update-index", "--cacheinfo", "100644," + oid + ",Source.swift")
        with patch.dict(os.environ, {"GIT_INDEX_FILE": str(self.good / ".git/index")}):
            with self.assertRaisesRegex(VERIFY.ParityError, "Index differs"):
                VERIFY.verify_git(self.bad, self.manifest, require_clean=True)

    def test_assume_unchanged_cannot_hide_uncommitted_proof_metadata(self):
        metadata = self.bad / "proof.json"
        metadata.write_text('{"trusted": true}\n')
        self.raw_git(self.bad, "add", "proof.json")
        self.raw_git(self.bad, "commit", "--quiet", "-m", "trusted proof metadata")
        self.manifest["allowed_nonruntime_files"] = ["proof.json"]
        metadata.write_text('{"trusted": false}\n')
        self.raw_git(self.bad, "update-index", "--assume-unchanged", "proof.json")
        self.assertEqual(self.raw_git(self.bad, "status", "--porcelain").strip(), b"")
        with self.assertRaisesRegex(VERIFY.ParityError, "Uncommitted proof metadata"):
            VERIFY.verify_git(self.bad, self.manifest, require_clean=True)


@unittest.skipUnless(SWIFTC, "Swift compiler unavailable; real maintained-source harness was not executed")
class NativeMaintainedSourceTests(unittest.TestCase):
    def run_swift(self, declarations, harness):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "main.swift"
            exe = Path(directory) / "source-contract"
            source.write_text("import Foundation\n" + declarations + "\n" + harness)
            result = subprocess.run([SWIFTC, str(source), "-o", str(exe)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("MAINTAINED_SOURCE_PASS", result.stdout)

    def test_real_two_factor_retry_and_phone_selection(self):
        source = (ROOT / "AltStore/AppDelegate.swift").read_text()
        declarations = section(source, "enum V3TwoFactorRetryPolicy", "struct V3AuthStartCancellationRegistry")
        declarations += section(source, "enum V3TwoFactorPhoneSelectionPolicy", "@MainActor\nfinal class V3HeadlessAuthHandler")
        self.run_swift(declarations, '''
precondition(V3TwoFactorRetryPolicy.shouldReuseCredentialsForCodeRetry(authFailureKind: "invalidCode"))
precondition(!V3TwoFactorRetryPolicy.shouldReuseCredentialsForCodeRetry(authFailureKind: "invalidCredentials"))
precondition(!V3TwoFactorRetryPolicy.shouldReuseCredentialsForCodeRetry(authFailureKind: nil))
precondition(V3TwoFactorPhoneSelectionPolicy.resolve(method: "sms", action: "phone:1", phoneIDs: ["1"]) == .requestSMS(phoneID: "1"))
precondition(V3TwoFactorPhoneSelectionPolicy.resolve(method: "voice", action: "phone:2", phoneIDs: ["2"]) == .requestVoice(phoneID: "2"))
precondition(V3TwoFactorPhoneSelectionPolicy.resolve(method: "sms", action: "phone:secret", phoneIDs: ["1"]) == .cancel)
precondition(V3TwoFactorPhoneSelectionPolicy.resolve(method: "sms", action: "changeMethod", phoneIDs: []) == .changeMethod)
print("MAINTAINED_SOURCE_PASS")
''')

    def test_real_keychain_pair_validation(self):
        app = (ROOT / "AltStore/AppDelegate.swift").read_text()
        keychain = (ROOT / "AltStore/Core/Components/Keychain.swift").read_text()
        declarations = section(app, "public enum LCAnisettePairError", "// V3_AUTHENTICATION_PHASE_EVIDENCE_V1")
        declarations += section(keychain, "struct LCAnisetteStoredPair", "struct LCEmbeddedAnisetteSnapshot")
        self.run_swift(declarations, '''
let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
let blob = Data([1, 2, 3])
let pair = LCAnisetteStoredPair(identifier: Data(id.uuidString.utf8), blob: Data(blob.base64EncodedString().utf8))
let value = try pair.validated()
precondition(value.identifier == id && value.blob == blob)
let empty = try LCAnisetteStoredPair(identifier: nil, blob: nil).validated()
precondition(empty.identifier == nil)
do { _ = try LCAnisetteStoredPair(identifier: nil, blob: Data("AQ==".utf8)).validated(); fatalError("orphan accepted") }
catch LCAnisettePairError.orphanedBlob {}
do { _ = try LCAnisetteStoredPair(identifier: Data("invalid".utf8), blob: nil).validated(); fatalError("invalid accepted") }
catch LCAnisettePairError.invalidIdentifier {}
print("MAINTAINED_SOURCE_PASS")
''')

    def test_real_finite_trace_rejects_injected_tokens(self):
        app = (ROOT / "AltStore/AppDelegate.swift").read_text()
        declarations = section(app, "public struct V3TemporaryAnisetteTrace", "struct V3AnisetteAttemptContext")
        self.run_swift(declarations, '''
precondition(V3TemporaryAnisetteTrace.temporaryAnisetteTraceEnabled)
var trace = V3TemporaryAnisetteTrace()
for _ in 0..<1000 { trace.record(step: .keychainRead, outcome: .started) }
let bounded = trace.snapshot!
precondition(bounded.utf8.count <= V3TemporaryAnisetteTrace.maximumBytes)
precondition(V3TemporaryAnisetteTrace(encoded: bounded) != nil)
precondition(V3TemporaryAnisetteTrace(encoded: "v1;password=secret") == nil)
trace.appendNative(errorDescription: "secret [DEBUG_TEMPORARY_NATIVE_TRACE:native.otp.failed]", scope: .primary)
precondition(!trace.snapshot!.contains("secret"))
print("MAINTAINED_SOURCE_PASS")
''')


if __name__ == "__main__":
    unittest.main(verbosity=2)
