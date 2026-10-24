"""Owned value/concurrency MODELS and exact Swift SOURCE contracts; no native/auth/import execution."""
import asyncio
import hashlib
import os
from pathlib import Path
import unittest

ROOT = Path(os.environ.get('BRIDGE_API_REPO_ROOT', Path(__file__).resolve().parents[2]))
APP = ROOT / 'AltStore/AppDelegate.swift'
RUNNER = ROOT / 'SideStore/Core/Operations/PipelineRunner.swift'
DEFAULTS = ROOT / 'AltStore/Core/Extensions/UserDefaults+AltStore.swift'
MODES = ('prompt-user', 'remove-all', 'keep-all', 'use-main-profile')


def effective(stored):
    if type(stored) is str and stored in MODES:
        return stored
    if type(stored) is bool:
        return 'prompt-user' if stored else 'keep-all'
    return 'prompt-user'


def project(stored):
    return effective(stored) == 'prompt-user'


def explicit_toggle(value):
    if type(value) is not bool:
        raise ValueError('not a strict Boolean')
    return 'prompt-user' if value else 'keep-all'


class PreferenceModels(unittest.TestCase):
    def test_all_four_policies_project_only_prompt_as_true(self):
        self.assertEqual([project(x) for x in MODES], [True, False, False, False])

    def test_legacy_true_is_prompt(self):
        self.assertEqual(effective(True), 'prompt-user')

    def test_legacy_false_is_keep_all_not_remove_all(self):
        self.assertEqual(effective(False), 'keep-all')

    def test_invalid_numbers_are_not_legacy_booleans(self):
        for x in (0, 1, 2, 0.0, 1.0):
            self.assertEqual(effective(x), 'prompt-user')

    def test_unknown_strings_and_missing_value_follow_upstream_default(self):
        for x in (None, '', '0', 'false', 'unknown', [], {}):
            self.assertEqual(effective(x), 'prompt-user')

    def test_explicit_toggle_writes_canonical_enum_and_round_trips(self):
        for value in (True, False):
            stored = explicit_toggle(value)
            self.assertIs(type(stored), str)
            self.assertEqual(project(stored), value)

    def test_explicit_setter_rejects_bool_coercion(self):
        for x in (None, 0, 1, 'true', 'false'):
            with self.assertRaises(ValueError): explicit_toggle(x)

    def test_read_keeps_existing_automatic_modes_unchanged(self):
        for stored in MODES:
            state = {'value': stored}
            project(state['value'])
            self.assertEqual(state, {'value': stored})

    def test_legacy_read_does_not_rewrite_storage(self):
        for stored in (True, False):
            state = {'value': stored}
            effective(state['value'])
            self.assertIs(state['value'], stored)


class ContextModels(unittest.TestCase):
    def test_host_group_keeps_context_reference_and_mutable_state(self):
        context = {'database': object(), 'steps': ['signIn'], 'error': object(), 'progress': [1, 2]}
        group = {'context': context}
        self.assertIs(group['context'], context)
        group['context']['progress'].append(3)
        self.assertEqual(context['progress'], [1, 2, 3])

    def test_database_entry_constructs_fresh_empty_context(self):
        database = object()
        one = {'database': database, 'steps': []}
        two = {'database': database, 'steps': []}
        self.assertIs(one['database'], two['database'])
        self.assertIsNot(one, two)
        self.assertEqual(one['steps'], [])


class ImportLifetimeModels(unittest.IsolatedAsyncioTestCase):
    async def exercise(self, outcome):
        entered, resume = asyncio.Event(), asyncio.Event()
        state = {'transition': False, 'settled': False, 'completions': 0}
        async def backend():
            entered.set()
            await resume.wait()
            if outcome == 'failure': raise ValueError('owned synthetic failure')
            return {'email': 'fake@example.invalid'}
        async def dispatch():
            state['transition'] = True
            try:
                return await backend()
            finally:
                state['transition'] = False
                state['completions'] += 1
        async def settle():
            try:
                return await dispatch()
            finally:
                state['settled'] = True
        task = asyncio.create_task(settle())
        await entered.wait()
        self.assertTrue(state['transition'])
        self.assertFalse(state['settled'])
        if outcome == 'cancel': task.cancel()
        else: resume.set()
        if outcome == 'success': self.assertEqual(await task, {'email': 'fake@example.invalid'})
        elif outcome == 'failure':
            with self.assertRaises(ValueError): await task
        else:
            with self.assertRaises(asyncio.CancelledError): await task
        self.assertFalse(state['transition'])
        self.assertTrue(state['settled'])
        self.assertEqual(state['completions'], 1)

    async def test_success_waits_before_identity_and_journal_completion(self): await self.exercise('success')
    async def test_failure_completes_identity_only_after_awaited_failure(self): await self.exercise('failure')
    async def test_cancellation_keeps_one_owned_completion(self): await self.exercise('cancel')


class SwiftSourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app, cls.runner, cls.defaults = APP.read_text(), RUNNER.read_text(), DEFAULTS.read_text()

    def test_both_runner_overloads_exist_without_replacing_upstream_entry(self):
        part = self.runner.split('func performSingleOperation(', 1)[1].split('func performVoidOperation(', 1)[0]
        self.assertEqual(self.runner.count('func performSingleOperation('), 2)
        self.assertIn('dbContext: NSManagedObjectContext', part)
        self.assertIn('StandaloneOperationContext(steps: [], dbBackgroundContext: dbContext)', part)
        self.assertIn('return self.performSingleOperation(operation, handler: handler, context: context,', part)
        self.assertIn('context: StandaloneOperationContext', part)
        self.assertIn('let group = RefreshGroup(context: context)', part)
        self.assertEqual(part.count('group.activeTask = Task.detached'), 1)

    def test_runner_completion_task_and_cancellation_keep_admitted_order(self):
        part = self.runner.split('        group.completionHandler =', 1)[1].split('    func performVoidOperation(', 1)[0]
        # Reviewed identity-continuity change: capture before detaching, retain the
        # route through work, then publish once on MainActor after the final check.
        self.assertEqual(hashlib.sha256(part.encode()).hexdigest(), 'd1990081f16c0df98972a50c8349cf29c6913f583dabd081b3c7a83da76c1954')
        order = ['completionHandler(.success(installedApp))',
                 'queuedAdmission = try V3RemoteRequestLeases.capture()',
                 'group.activeTask = Task.detached {', 'defer { queuedAdmission.close() }',
                 'try await queuedAdmission.withScope {',
                 'try await self.perform([operation], handler: handler, group: group)',
                 'try await MainActor.run {', 'try queuedAdmission.check()',
                 'queuedAdmission.close()\n', 'group.completionHandler?(group.results)']
        positions = [part.index(text) for text in order]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(part.count('group.activeTask = Task.detached {'), 1)
        self.assertEqual(part.count('group.completionHandler?(group.results)'), 1)
        publication = part.split('group.completionHandler?(group.results)', 1)[1].split('} catch {', 1)[0]
        self.assertNotIn('try ', publication)  # No post-callback failure/double delivery.
        cancellation = part.split('if Task.isCancelled || error is CancellationError {', 1)[1]
        self.assertLess(cancellation.index('completionHandler(.failure(OperationError.cancelled))'),
                        cancellation.index('return'))
        self.assertLess(cancellation.index('return'), cancellation.index('completionHandler(.failure(error))'))
        pipeline = self.runner.split('private func performUsingAdmittedRoute(', 1)[1].split('func performOperation(', 1)[0]
        self.assertNotIn('completionHandler', pipeline)  # Only outer entry owns publication.

    def test_host_calls_keep_shared_context_not_only_database(self):
        single = self.app.split('private func single(id:', 1)[1].split('private func isDeleteCancellationError', 1)[0]
        delete = self.app.split('private func deleteAndReconcile(id:', 1)[1].split('let deadline =', 1)[0]
        self.assertIn('handler: handler, context: context)', single)
        self.assertIn('handler: handler, context: context', delete)
        self.assertNotIn('dbContext:', single + delete)
        self.assertIn('group.cancel(); group.progress.cancel()', single)
        self.assertIn('group.cancel(); group.progress.cancel()', delete)

    def test_host_settings_projection_and_canonical_write_are_symmetric(self):
        get = self.app.split('static func settingsGet()', 1)[1].split('static func settingsSet(', 1)[0]
        set_ = self.app.split('static func settingsSet(', 1)[1].split('} else if key == "widgetVerboseLogging"', 1)[0]
        self.assertIn('bools["customizeAppExtensions"] = UserDefaults.standard.customizeAppExtensions == .promptUser', get)
        self.assertIn('V3WireContract.strictBool(payload["bool"])', set_)
        self.assertIn('UserDefaults.standard.customizeAppExtensions = value ? .promptUser : .keepAll', set_)
        self.assertNotIn('.set(', get)
        self.assertIn('} else {\n                UserDefaults.standard.set(value, forKey: key)', set_)

    def test_legacy_getter_is_read_only_and_rejects_nonboolean_numbers(self):
        part = self.defaults.split('var customizeAppExtensions: AppExtensionCustomization', 1)[1].split('    @objc(customizeAppExtensions)', 1)[0]
        get = part.split('        set {', 1)[0]
        self.assertIn('AppExtensionCustomization(rawValue: $0)', get)
        self.assertIn('CFGetTypeID(legacy) == CFBooleanGetTypeID()', get)
        self.assertIn('return legacy.boolValue ? .promptUser : .keepAll', get)
        self.assertNotIn('self.set(', get)
        self.assertNotIn('removeObject', get)
        self.assertIn('_customizeAppExtensions = newValue.rawValue', part)

    def test_async_import_chain_keeps_identity_transition_defer(self):
        dispatch = self.app.split('case "accountImport":\n            guard let answer', 1)[1].split('default: throw ServiceError.invalidRequest', 1)[0]
        begin = dispatch.index('AuthManager.shared.v3BeginIdentityTransition()')
        defer = dispatch.index('defer { AuthManager.shared.v3CompleteIdentityTransition() }')
        await_ = dispatch.index('return try await V3BackendCommands.accountImport(')
        self.assertLess(begin, defer)
        self.assertLess(defer, await_)
        bridge = self.app.split('static func accountImport(token:', 1)[1].split('\n    }', 1)[0]
        self.assertIn('async throws -> [String: Any]', bridge)
        self.assertIn('try await ImportExport.importAccount(data, filePassword: password)', bridge)
        self.assertNotIn('Task {', dispatch + bridge)
        self.assertNotIn('Task.detached', dispatch + bridge)


if __name__ == '__main__':
    unittest.main()
