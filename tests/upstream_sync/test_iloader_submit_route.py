"""Synthetic/source checks only: no native execution, live auth or provider requests."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
HOST = (ROOT / "LiveContainer/LiveContainerSwiftUI/Views/V3UnifiedShell.swift").read_text()
SERVICE = (ROOT / "SideStore/AltStore/AppDelegate.swift").read_text()
OPERATION = (ROOT / "SideStore/SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift").read_text()
PROVIDER = (ROOT / "SideStore/SideStore/Core/Anisette/AnisetteProvider.swift").read_text()


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

    def test_inline_disclosure_precedes_existing_submit(self):
        section = HOST[HOST.index("struct V3PromptSection:"):HOST.index("final class V3AuthStore:")]
        self.assertIn('@State private var useRemoteMacAnisette = false', section)
        self.assertIn('prompt["remoteMacAnisette"] as? String == "submit-v1"', section)
        self.assertLess(section.index('signin.remote-mac-anisette.disclosure'), section.index('Button("Submit")'))
        self.assertIn('mac-ani.jkcoxson.com', section)
        self.assertIn('password and verification code are sent only to Apple', section)
        self.assertIn('Remote identity and ADI state stay in memory', section)
        self.assertIn('The provider can correlate this activity', section)
        self.assertNotIn('.alert(', section)
        self.assertIn('answer["anisetteProvider"] = "remoteMac"', section)
        self.assertGreaterEqual(section.count('useRemoteMacAnisette = false'), 3)

    def test_service_checks_capability_before_delivering_answer(self):
        respond = SERVICE[SERVICE.index('func respond(id: String, promptID: String, answer: [String: String])'):]
        respond = respond[:respond.index('func expire(id:')]
        self.assertLess(respond.index('if let provider = answer["anisetteProvider"]'),
                        respond.index('prompts.answer(promptID:'))
        for fragment in ['provider == "remoteMac"', '== "credentials"', '== "submit-v1"',
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
        factory = PROVIDER[PROVIDER.index('func makeILoaderRemoteAuthenticationContext()'):]
        for forbidden in ['Keychain', 'UserDefaults', 'resolveAnisetteSnapshot', 'commitAnisetteBlob']:
            self.assertNotIn(forbidden, factory)

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
