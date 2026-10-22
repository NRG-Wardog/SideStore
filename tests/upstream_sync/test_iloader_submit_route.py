"""Synthetic/source checks only: no native execution, live auth or provider requests."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
HOST = (ROOT / "LiveContainer/LiveContainerSwiftUI/Views/V3UnifiedShell.swift").read_text()
SERVICE = (ROOT / "SideStore/AltStore/AppDelegate.swift").read_text()
OPERATION = (ROOT / "SideStore/SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift").read_text()
PROVIDER = (ROOT / "SideStore/SideStore/Core/Anisette/AnisetteProvider.swift").read_text()
KEYCHAIN = (ROOT / "SideStore/AltStore/Core/Components/Keychain.swift").read_text()


def declaration(source, signature):
    """Bound a known Swift declaration by its balanced body, not the file tail."""
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("Unclosed Swift declaration: " + signature)


class AttemptModel:
    """Review model for the one-shot route contract, not a Swift runtime test."""
    def __init__(self, mode="interactive"):
        self.mode = mode
        self.selection = None
        self.invalidated = False

    def accepts(self, kind="credentials", provider=None):
        if provider is None:
            return True
        return (provider == "remoteMac" and kind == "credentials" and
                self.mode == "interactive" and self.selection is None)

    def submit(self, provider=None):
        if not self.accepts(provider=provider):
            raise ValueError("route not offered")
        if self.selection is None:
            self.selection = provider == "remoteMac"

    def fetch_route(self):
        if self.selection and self.invalidated:
            raise ValueError("remote invalidated")
        return "remote" if self.selection else "default"

    def delivery_methods(self):
        return [method for method in ["trustedDevice", "sms", "voice", "cancel"]
                if not self.selection or method != "voice"]


class SubmitRouteTests(unittest.TestCase):
    def test_default_and_omitted_selection_remain_default(self):
        attempt = AttemptModel()
        attempt.submit()
        self.assertEqual(attempt.fetch_route(), "default")
        attempt.submit()
        self.assertEqual(attempt.fetch_route(), "default")

    def test_first_submit_latches_remote(self):
        attempt = AttemptModel()
        attempt.submit("remoteMac")
        self.assertEqual(attempt.fetch_route(), "remote")
        self.assertFalse(attempt.accepts(provider="remoteMac"))

    def test_local_retry_cannot_switch_provider(self):
        attempt = AttemptModel()
        attempt.submit()
        with self.assertRaises(ValueError):
            attempt.submit("remoteMac")
        self.assertEqual(attempt.fetch_route(), "default")

    def test_two_factor_and_other_prompts_reject_provider(self):
        for kind in ["twoFactor", "team", "accountRepair", "provisioning"]:
            self.assertFalse(AttemptModel().accepts(kind, "remoteMac"))

    def test_reauthentication_and_resume_reject_remote(self):
        for mode in ["reauthenticateProvisioning", "resumeProvisioning"]:
            self.assertFalse(AttemptModel(mode).accepts(provider="remoteMac"))

    def test_unknown_provider_and_url_rejected(self):
        for value in ["", "local", "remote", "https://mac-ani.jkcoxson.com", "remoteMac "]:
            self.assertFalse(AttemptModel().accepts(provider=value))

    def test_cancel_keeps_remote_sentinel_and_fails_closed(self):
        attempt = AttemptModel()
        attempt.submit("remoteMac")
        attempt.invalidated = True
        with self.assertRaises(ValueError):
            attempt.fetch_route()
        self.assertTrue(attempt.selection)

    def test_new_attempt_starts_default(self):
        previous = AttemptModel()
        previous.submit("remoteMac")
        previous.invalidated = True
        new = AttemptModel()
        new.submit()
        self.assertEqual(new.fetch_route(), "default")

    def test_remote_omits_voice_without_changing_local_delivery_choices(self):
        local = AttemptModel()
        local.submit()
        self.assertEqual(local.delivery_methods(), ["trustedDevice", "sms", "voice", "cancel"])
        remote = AttemptModel()
        remote.submit("remoteMac")
        self.assertEqual(remote.delivery_methods(), ["trustedDevice", "sms", "cancel"])
        handler = SERVICE[SERVICE.index('final class V3HeadlessAuthHandler:'):]
        chooser = handler[handler.index('private func chooseDeliveryMethod('):handler.index('private func enterVerificationCode(')]
        self.assertIn('].filter { remoteMacAnisetteSelection != true || $0["id"] != "voice" }', chooser)
        self.assertIn('guard method != "voice" || remoteMacAnisetteSelection != true else { return .cancel }', chooser)

    def test_ui_defaults_supported_manual_submit_without_toggle_or_inline_explanation(self):
        section = HOST[HOST.index("struct V3PromptSection:"):HOST.index("final class V3AuthStore:")]
        self.assertIn('kind == "credentials" && prompt["remoteMacAnisette"] as? String == "submit-v2"', section)
        self.assertIn('if usesRemoteMacAnisetteForSubmit {', section)
        self.assertIn('answer["anisetteProvider"] = "remoteMac"', section)
        self.assertNotIn('useRemoteMacAnisette', section)
        self.assertNotIn('Toggle("Use Remote Mac', section)
        self.assertNotIn('signin.remote-mac-anisette.disclosure', section)
        self.assertNotIn('mac-ani.jkcoxson.com', section)
        self.assertIn('SecureField(', section)
        submit = section[section.index('private func submit(choice:'):section.index('private func respond(')]
        self.assertLess(submit.index('answer["anisetteProvider"]'), submit.index('respond(answer)'))

    def test_new_host_requires_exact_v2_prompt_and_old_clients_stay_local(self):
        def host_answer(kind, capability):
            return {"anisetteProvider": "remoteMac"} if kind == "credentials" and capability == "submit-v2" else {}
        self.assertEqual(host_answer("credentials", "submit-v2"), {"anisetteProvider": "remoteMac"})
        for capability in [None, "submit-v1", "submit-v3", "submit-v2 "]:
            self.assertEqual(host_answer("credentials", capability), {})
        for kind in ["twoFactor", "provisioning", "team"]:
            self.assertEqual(host_answer(kind, "submit-v2"), {})
        legacy = AttemptModel()
        legacy.submit()
        self.assertEqual(legacy.fetch_route(), "default")
        modern = AttemptModel()
        modern.submit(host_answer("credentials", "submit-v2")["anisetteProvider"])
        self.assertEqual(modern.fetch_route(), "remote")

    def test_initial_draft_cannot_submit_or_grant_remote(self):
        draft = HOST[HOST.index('private var displayedPrompt: [String: Any]?'):]
        draft = draft[:draft.index('private var shouldShowAccountSection:')]
        self.assertNotIn('remoteMacAnisette', draft)
        self.assertIn('isSubmissionBlocked: showsInitialCredentialDraft ||', HOST)

    def test_service_checks_capability_before_delivering_answer(self):
        respond = SERVICE[SERVICE.index('func respond(id: String, promptID: String, answer: [String: String])'):]
        respond = respond[:respond.index('func expire(id:')]
        self.assertLess(respond.index('if let provider = answer["anisetteProvider"]'),
                        respond.index('prompts.answer(promptID:'))
        for fragment in ['provider == "remoteMac"', '== "credentials"', '== "submit-v2"',
                         'session.mode == .interactive']:
            self.assertIn(fragment, respond)

    def test_handler_latches_once_and_advertises_only_fresh_interactive_prompt(self):
        handler = SERVICE[SERVICE.index('final class V3HeadlessAuthHandler:'):]
        credentials = handler[handler.index('func credentials()'):handler.index('func verificationCode(')]
        self.assertIn('remoteMacAnisetteSelection == nil && expectedOwner == nil', credentials)
        self.assertIn('?.mode == .interactive', credentials)
        self.assertIn('if remoteMacAnisetteSelection == nil {', credentials)
        self.assertIn('guard offersRemote, provider == "remoteMac"', credentials)
        self.assertIn('v3RemoteAnisetteSelection: { try handler.remoteMacAnisetteSelected() }', SERVICE)

    def test_operation_routes_only_after_credentials(self):
        loop = OPERATION[OPERATION.index('private func authenticationLoop()'):OPERATION.index('private func v3ValidateReauthenticationIdentity')]
        self.assertLess(loop.index('handler.credentials()'), loop.index('v3ResolveAnisetteRouteAfterCredentials()'))
        self.assertLess(loop.index('v3ResolveAnisetteRouteAfterCredentials()'), loop.index('self.signIn(appleID:'))
        self.assertIn('guard !v3AnisetteRouteResolved else { return }', OPERATION)
        self.assertIn('let selected = try await v3RemoteAnisetteSelection?() ?? false', OPERATION)
        self.assertIn('if self.v3RemoteContextSnapshot() != nil { throw error }', loop)
        self.assertLess(loop.index('if self.v3RemoteContextSnapshot() != nil { throw error }'),
                        loop.index('shouldReuseCredentialsForCodeRetry'))

    def test_context_is_retained_on_invalidation_and_never_persisted(self):
        self.assertIn('defer { v3RemoteContextSnapshot()?.invalidate() }', OPERATION)
        self.assertIn('self.v3RemoteContextSnapshot()?.invalidate()', OPERATION)
        self.assertNotIn('v3RemoteAnisetteContext = nil', OPERATION)
        self.assertIn('ILoaderRemoteAuthentication.$current.withValue(remote)', OPERATION)
        factory = declaration(PROVIDER, 'func makeILoaderRemoteAuthenticationContext()')
        self.assertIn('try V3RemoteIdentityContinuity.manualAttempt().context', factory)
        attempt = declaration(PROVIDER, 'final class V3RemoteAnisetteAttempt:')
        self.assertIn('canceller: { source.invalidate() }', attempt)
        self.assertIn('V3RemoteRequestLeases.registerManual(context, id: registrationID)', attempt)
        for forbidden in ['Keychain', 'UserDefaults', 'resolveAnisetteSnapshot', 'commitAnisetteBlob']:
            self.assertNotIn(forbidden, factory + attempt)
        # Approval covers isolated identity/registration bytes, not revocable
        # contexts, OTPs, headers or another copy of account credentials.
        manual = declaration(PROVIDER, 'static func manualAttempt()')
        self.assertIn('Keychain.shared.remoteIdentityRecord()', manual)
        commit = declaration(PROVIDER, 'static func commit(_ handoff:')
        self.assertIn('handoff.state.profile.endpoint == .macJkcoxson', commit)
        self.assertIn('Keychain.shared.commitRemoteIdentity(record,', commit)
        record = declaration(KEYCHAIN, 'struct V3RemoteIdentityRecord:')
        stored = re.findall(r'^    (?:let|var) (\w+): ([^\n{]+)$', record, re.MULTILINE)
        self.assertEqual(stored, [('schemaVersion', 'Int'), ('identityID', 'String'),
                                 ('endpoint', 'String'), ('identity', 'Data'),
                                 ('adiPB', 'String'), ('routeBinding', 'Data?')])
        adapter = declaration(KEYCHAIN, 'static func remoteIdentityClient()')
        self.assertIn('V3PendingCertificateKeychainClient(service: service + ".remote-anisette", accessGroup: group)', adapter)
        security = declaration(KEYCHAIN, 'struct V3PendingCertificateKeychainClient')
        self.assertIn('kSecAttrSynchronizable: false', security)
        self.assertIn('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly', security)
        for forbidden in ['ILoaderRemoteAuthenticationContext', 'UserDefaults', 'commitAnisetteBlob']:
            self.assertNotIn(forbidden, record + adapter + commit)

    def test_remote_keeps_existing_diagnostic_spans_and_typed_category(self):
        fetch = OPERATION[OPERATION.index('private func getAnisetteData()'):OPERATION.index('private func v3RemoteContextSnapshot()')]
        for required in ['v3LoginStage(.anisetteFetch)', 'v3AuthenticationPhase(.anisetteFetch)',
                         'beginProviderObservation(.selectedBranch(onDevice: false))',
                         'remote.fetch()', 'AnisetteProvider.fetch(handler: self.anisetteServerHandler)']:
            self.assertIn(required, fetch)
        diagnostic = SERVICE[SERVICE.index('else if let remote = error as? ILoaderRemoteError'):]
        diagnostic = diagnostic[:diagnostic.index('else if let anisette = error as? SideSign.AnisetteError')]
        self.assertIn('kind = .anisetteFailure', diagnostic)
        self.assertIn('(100...599).contains(status)', diagnostic)
        self.assertNotIn('localizedDescription', diagnostic)


if __name__ == '__main__':
    unittest.main()
