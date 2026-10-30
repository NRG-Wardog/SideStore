"""Actual policy/coordinator execution; platform/storage/crypto are explicit fixture boundaries."""
import pathlib, subprocess, shutil, tempfile, unittest, os
ROOT=pathlib.Path(__file__).resolve().parents[2]
SOURCE=ROOT/'AltStore/AppDelegate.swift'
def source():
 text=SOURCE.read_text();start=text.index('struct V3LegacyReplacementBinding:');end=text.index('// MARK: - Headless operation sessions',start)
 return text[start:end]
class Contract(unittest.TestCase):
 def test_actual_source_closure(self):
  text=source()
  self.assertIn('tokens.removeValue(forKey: token)',text)
  self.assertIn('reservedSessions.removeValue(forKey: token) == session',text)
  self.assertIn('snapshotContext.performAndWait',text)
  self.assertLess(text.index('AppBundleFingerprint.compute(for:'),text.index('AppBundleFingerprint.computeOriginalCacheKey'))
  self.assertIn('signer.x509.data == der',text)
  self.assertIn('signer.x509.serialNumber == historical.serialNumber',text)
  self.assertNotIn('DeveloperPortalProxy',text)
  self.assertNotIn('installIPA(',text)
 def test_owned_driver_and_consent(self):
  text=SOURCE.read_text();a=text.index('case "legacyReplacement":\n            let assessment');b=text.index('case "install", "installURL"',a)
  driver=text[a:b]
  for expected in ['consume(target, session: id)','session.deadline > Date()','!session.terminal.isCancellationRequested','self.activeMutationID == id','.resign(app, alternateIconMode: .preserve)','legacyReplacementBinding: assessment.binding']:
   self.assertIn(expected,driver)
  self.assertIn('!V3LegacyReplacementPolicy.consent(payload["riskAcknowledgmentVersion"]',text)
  self.assertIn('"legacyReplacement"].contains(kind)',text)
 def test_native_policy_and_coordinator(self):
  compiler=shutil.which('swiftc')
  if not compiler:
   if os.getenv('REQUIRE_NATIVE_LEGACY_REPLACEMENT')=='1':self.fail('swiftc required')
   self.skipTest('Swift unavailable locally; native qualification required')
  with tempfile.TemporaryDirectory() as raw:
   root=pathlib.Path(raw).resolve();unit=root/'Main.swift';exe=root/'checks'
   unit.write_text((ROOT/'tests/legacy_replacement/Boundary.swift').read_text()+source()+(ROOT/'tests/legacy_replacement/Cases.swift').read_text())
   built=subprocess.run([compiler,'-swift-version','5','-parse-as-library',str(unit),'-o',str(exe)],capture_output=True,text=True,timeout=180)
   self.assertEqual(built.returncode,0,built.stdout+built.stderr)
   run=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
   self.assertEqual(run.returncode,0,run.stdout+run.stderr)
   self.assertIn('LEGACY_REPLACEMENT_POLICY_PASS cases=42',run.stdout)
   print(run.stdout,end='')
 def test_counterfactual_guards_are_observed(self):
  compiler=shutil.which('swiftc')
  if not compiler:
   if os.getenv('REQUIRE_NATIVE_LEGACY_REPLACEMENT')=='1':self.fail('swiftc required')
   self.skipTest('Swift unavailable locally; counterfactual execution required in native CI')
  mutations={
   'nonce replay':lambda text:text.replace('reservedSessions.removeValue(forKey: token) == session','reservedSessions[token] == session').replace('tokens.removeValue(forKey: token), assessment.expires','tokens[token], assessment.expires'),
   'stale record':lambda text:text.replace('guard binding == assessment.binding else','guard true else'),
   'consent bypass':lambda text:text.replace('integer(value, equals: 1) && V3WireContract.strictBool(confirmed) == true','true'),
  }
  verified=[]
  for name,mutate in mutations.items():
   with self.subTest(name=name),tempfile.TemporaryDirectory() as raw:
    root=pathlib.Path(raw).resolve();unit=root/'Main.swift';exe=root/'checks'
    original=source();changed=mutate(original);self.assertNotEqual(original,changed)
    unit.write_text((ROOT/'tests/legacy_replacement/Boundary.swift').read_text()+changed+(ROOT/'tests/legacy_replacement/Cases.swift').read_text())
    built=subprocess.run([compiler,'-swift-version','5','-parse-as-library',str(unit),'-o',str(exe)],capture_output=True,text=True,timeout=180)
    self.assertEqual(built.returncode,0,built.stdout+built.stderr)
    run=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
    self.assertNotEqual(run.returncode,0,'Removed guard escaped the actual-source fixture: '+name)
    self.assertNotIn('LEGACY_REPLACEMENT_POLICY_PASS',run.stdout)
    verified.append(name)
  self.assertEqual(len(verified),3)
  print('LEGACY_REPLACEMENT_COUNTERFACTUAL_PASS variants=nonce,stale,consent')
if __name__=='__main__':unittest.main()
