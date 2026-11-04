#!/usr/bin/env python3
"""Source integration and deterministic fixture closure, not Swift execution."""
from pathlib import Path
import hashlib, json, tempfile, unittest
import generate
ROOT=generate.ROOT
class InitialRejectionSourceTests(unittest.TestCase):
 def test_actual_source_closure(self):
  with tempfile.TemporaryDirectory() as directory:
   output=Path(directory);generate.generate(output,ROOT/'Dependencies/SideSign')
   value=json.loads((output/'source-evidence.json').read_text())
   self.assertFalse(value['swift_executed'])
   self.assertEqual(len(value['outputs']),8)
   for name, digest in value['outputs'].items(): self.assertEqual(hashlib.sha256((output/name).read_bytes()).hexdigest(),digest)
   for suffix in ['Sources/DeveloperPortal/Authentication.swift','initial-provider-rejection/authentication-projection.json','StandaloneOperations/SignInOperation.swift','Anisette/V3DiagnosticProviderSequence.swift']:
    self.assertTrue(any(path.endswith(suffix) for path in value['inputs']),suffix)
   consumer=(output/'RetryConsumer.swift').read_text()
   self.assertIn('private func diagnosticRetryFailure(',consumer)
   self.assertIn('func v3AuthenticationPhase<T>(',consumer)
   self.assertIn('struct V3DiagnosticProviderSequence:',consumer)
   self.assertIn('rejection.matches(ownedContext)',consumer)
 def test_join_cleanup_binding_and_identity_before_next(self):
  text=(ROOT/'SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift').read_text()
  body=text.split('private func diagnosticAuthentication(',1)[1].split('private func diagnosticRetryFailure(',1)[0]
  ordered=['withThrowingTaskGroup','defer { group.cancelAll() }','let failedOwnedContext = v3OwnedODAContextSnapshot()','if let owned = failedOwnedContext','await owned.finish()','if isCancelled || Task.isCancelled || v3IsAuthCancellation(error)','ownedContext: failedOwnedContext','if challengeSeen { sequence.needsUser(attempt) }','sequence.failed(attempt','sequence.previousAttemptStopped(attempt','credentialsCommitted: identityStamp != AuthManager.shared.v3IdentityStamp','sequence.continueAfterBackoff']
  position=0
  for item in ordered: position=body.index(item,position)+len(item)
  self.assertIn('identityStamp == AuthManager.shared.v3IdentityStamp',body)
  self.assertNotIn('reset',body.lower())
 def test_terminal_diagnostics_are_typed_and_finite(self):
  text=(ROOT/'AltStore/AppDelegate.swift').read_text()
  branch=text.split('else if error is OwnedODAInitialProviderRejection {',1)[1].split('}',1)[0]
  self.assertIn('kind = .sideSignServerReportedError',branch)
  self.assertIn('serverCode = OwnedODAInitialProviderRejection.serverCode',branch)
  self.assertIn('httpStatus = 200',branch)
 def test_constructor_private_and_only_first_init(self):
  text=(ROOT/'Dependencies/SideSign/Sources/DeveloperPortal/Authentication.swift').read_text()
  self.assertIn('fileprivate init(context:',text)
  self.assertEqual(text.count('initialOwnedAttempt: initialInvocation'),1)
  self.assertIn('AuthenticationInvocationDepth.current == 0',text)
  self.assertIn('initialOwnedAttempt: Bool = false',text)
  self.assertIn('requestParameters["o"] as? String == "init"',text)
  self.assertIn('try context.checkActive()\n        return Self(context: context)',text)
if __name__=='__main__': unittest.main()
