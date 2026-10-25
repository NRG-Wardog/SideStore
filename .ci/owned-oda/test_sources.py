import json,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class OwnedODAIntegrationTests(unittest.TestCase):
 def test_scope_and_drain(self):
  text=(ROOT/'SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift').read_text()
  self.assertGreaterEqual(text.count('try await self.v3WithOwnedODA {'),4)
  self.assertNotIn('self.v3LoginStageSync',text)
  self.assertNotIn('self.v3AccountOperationFailure',text)
  self.assertIn('if let owned = v3OwnedODAContextSnapshot() { await owned.finish() }',text)
  self.assertIn('installSession: { AuthManager.shared.session = session }',text)
  self.assertIn('if ownedODA == nil { v3LoginStageSync(.sessionCommit)',text)
  self.assertIn('v3CompleteOwnedODAIdentityTransition(reserved)',text)
  self.assertIn('try self.v3OwnedODAContextSnapshot()?.checkActive()',text)
 def test_queued_owner_and_commit_gate(self):
  text=(ROOT/'SideStore/Core/Anisette/AnisetteProvider.swift').read_text()
  for value in ['ownedODAContext', 'OwnedODAAuthentication.$current.withValue', 'context.commitStagedBlob(blob)', 'v3CommitDuringOwnedODAIdentityTransition', 'commitAnisetteBlob', 'installSession()']:
   self.assertIn(value,text)
  owned=text.split('final class V3OwnedODAAttempt:',1)[1]
  self.assertEqual(owned.count('UserDefaults.standard.menuAnisetteList'),1)
  proxy=(ROOT/'SideStore/Core/Auth/DeveloperPortalProxy.swift').read_text()
  self.assertIn('OwnedODAAuthentication.$current.withValue(context.admission.ownedODAContext)',proxy)
 def test_generator_other_cwd_symlink_parent(self):
  with tempfile.TemporaryDirectory() as temp:
   base=Path(temp).resolve(); link=base/'alias';link.symlink_to(ROOT,target_is_directory=True)
   out=base/'out'
   subprocess.run([sys.executable,str(link/'.ci/owned-oda/generate_identity.py'),'--output',str(out)],cwd=base,check=True,timeout=15)
   result=(out/'Identity.swift').read_text()
   self.assertIn('func commitDuringOwnedTransition',result)
   self.assertIn('func beginTransition(ifCurrent',result)
   self.assertEqual(len(json.loads((out/'source-evidence.json').read_text())['source_sha256']),64)
if __name__=='__main__':unittest.main()
